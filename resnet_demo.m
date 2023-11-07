%% Set up project
clear;
reset_persistent;

fprintf('Starting, %s\n', datetime());

desktop_env = ispc();
has_gui = false;

if (desktop_env)
  % Set up project for desktop environment

  % Override default data directory to local storage
  data_dir_override = 'D:/data/';
  if ~exist(data_dir_override, 'dir')
    error('Data override directory does not exist');
  end
  setenv('NANOGRID_DATA_DIR', data_dir_override);
  
  project_setup;
  
  setenv('NANOGRID_DATA_DIR');  % Clear data directory override

  has_gui = true;
else
  % Set up project for console or non-interactive environment
  project_setup;
end

% Initialize monitor
monitor.name = 'Training monitor';
monitor.gui_monitor = [];
monitor.training_csv_file = fullfile(output_dir, 'training.csv');
monitor.validation_csv_file = fullfile(output_dir, 'validation.csv');
monitor.losses = [];
monitor.epoch = 0;
monitor.iteration = 0;
monitor.console_update_counter = 0;
monitor.console_update_iterations = 25;

% Check for GUI interface
fprintf('Has graphical interface: %s\n', mat2str(has_gui));

% Check for GPUs
gpus_available = gpuDeviceCount("available");

if (gpus_available > 0)
  fprintf('Using GPU\n');
  executionEnvironment = "gpu";
else
  fprintf('No GPUs found\n');
end

% Get global parameters
gp = global_params();

%% Set up datastore
mini_batch_size = ceil(gp.samples_per_cycle / gp.min_sequence_len) * gp.strides_per_sequence;
if (gpus_available > 0)
  mini_batch_size = mini_batch_size * 40;
else
  mini_batch_size = mini_batch_size * 2;
end

fprintf('Initializing datastores, %s\n', datetime());
tic;

% Get training file set and create source datastore
ds_fileset = matlab.io.datastore.DsFileSet(training_data_dir, ...
  'IncludeSubfolders', true);

ds_source = fileDatastore(ds_fileset, ...
  'ReadFcn', @dtinfo_ds_reader);

% Create an 80/20 split for training/validation
% TODO: Is there a more elegant way to do this?
training_ds = combine(...
  partition(ds_source, 5, 1), ...
  partition(ds_source, 5, 2), ...
  partition(ds_source, 5, 3), ...
  partition(ds_source, 5, 4), ...
  'ReadOrder', 'sequential');

validation_ds = combine(...
  partition(ds_source, 5, 5), ...
  'ReadOrder', 'sequential');

% Add transform functions to datastores
training_ds = transform(training_ds, ...
  @(ds_in) dtinfo_ds_transform(ds_in));

validation_ds = transform(validation_ds, ...
  @(ds_in) dtinfo_ds_transform(ds_in));

% Create minibatch queues
training_batch_queue = minibatchqueue(training_ds, ...
  'MiniBatchFormat', {'CTB'}, ...
  'MiniBatchSize', mini_batch_size, ...
  'PartialMiniBatch', 'discard');

validation_batch_queue = minibatchqueue(validation_ds, ...
  'MiniBatchFormat', {'CTB'}, ...
  'MiniBatchSize', mini_batch_size, ...
  'PartialMiniBatch', 'discard');

fprintf('Datastores initialized\n');
toc;

%% Create network
fprintf('Creating network, %s\n', datetime());
tic;

model_params = [];

if isfile('debug_model.mat')
  % Load saved model for debugging
  debug_model = load('debug_model.mat');
  model = debug_model.model;
  model_params = debug_model.model_params;
  clear debug_model;

  fprintf('[%s] WARNING: Using debug model\n', datetime());

else
  % Set model parameters
  model_params.filter_size = 3;
  model_params.num_filters = gp.num_features * 16;
  
  model_params.num_res_blocks = 4;

  model_params.encoder_hidden_size = gp.num_features * 4;
  model_params.latent_dims = gp.num_features;
  
  % Create model
  [model, training_params] = create_resnet(model_params);
end

model_eval_cb = @evaluate_resnet;
model_update_cb = @update_resnet;

%% Train and monitor progress
% Initialize training parameters
training_params.learn_rate = 2e-4;
training_params.monte_carlo_reps = 3;

training_params.recon_loss_factor = 1;
training_params.kl_loss_factor = 1;

training_params.min_recon_loss = 10000;

% Initialize output, counters, etc.
create_output_dir();

checkpoint_iteration_count = 1000;
checkpoint_counter = 0;

validation_iteration_count = 3;
validation_counter = 0;

% Initialize training loop values
epoch_count = 20;

epoch = 0;
iteration = 0;

% Create GUI monitor if GUI is available
if (has_gui)
  monitor.gui_monitor = create_gui_monitor();
end

% Start training
fprintf('Starting training, %s\n', datetime());
try
  while epoch < epoch_count && ~stop_requested(monitor)
    % Increment epoch count and reset counters
    epoch = epoch + 1;
    epoch_iteration = 0;
  
    % Shuffle data
    shuffle(training_batch_queue);
    shuffle(validation_batch_queue);

    % Process minibatches until out of data (or stop requested)
    epoch_start_time = tic;
    while hasdata(training_batch_queue) && ~stop_requested(monitor)
      iteration = iteration + 1;
      epoch_iteration = epoch_iteration + 1;

      training_params.epoch = epoch;
      training_params.iteration = iteration;
  
      % Evaluate and update model with a training batch
      batch = next(training_batch_queue);

      [losses, grads, training_params] = dlfeval(model_eval_cb, model, batch, training_params);
      [model, training_params] = model_update_cb(model, losses, grads, training_params);
    
      % Update monitor
      monitor.epoch = epoch;
      monitor.iteration = iteration;
      monitor.losses = losses;
      monitor = update_monitor(monitor);

      % Test performance on validation data
      if (validation_counter > 0)
        validation_counter = validation_counter - 1;
      else
        % Reset counter
        validation_counter = validation_iteration_count - 1;
        
        validation_batch = next(validation_batch_queue);
        perform_validation(model_eval_cb, model, ...
          validation_batch, training_params, monitor);
      end
  
      % Perform checkpoint operations
      if (checkpoint_counter > 0)
        checkpoint_counter = checkpoint_counter - 1;
      else
        % Reset counter
        checkpoint_counter = checkpoint_iteration_count - 1;

        % Save model
        checkpoint_file = fullfile(output_dir, ...
          sprintf('checkpoint-e%d-i%d.mat', epoch, epoch_iteration));
        save(checkpoint_file, 'model');
      end
  
    end
    epoch_duration = toc(epoch_start_time);

    % Save model after every epoch
    try
      model_filename = sprintf('res-epoch-%d.mat', epoch);
      save(fullfile(output_dir, model_filename), 'model');
    catch ex
      fprintf('[%s] ERROR: Failed to save model after epoch: %s\n%s\n', ...
          datetime(), ...
          ex.identifier, ...
          ex.message);
        % TODO: Ignore this exception or do something else with it?
    end

    % Display timing info
    fprintf('Epoch timing: %f seconds per iteration, %d iterations\n', ...
      epoch_duration / epoch_iteration, ...
      epoch_iteration);
  end

  % Done!

catch ex
  % Save model and model parameters for debugging
  save(fullfile(output_dir, 'debug_model.mat'), 'model', ...
    'model_params', 'training_params');
  rethrow(ex);

end


%% Helper functions
function monitor = create_gui_monitor()
  monitor = trainingProgressMonitor( ...
    Metrics = ["Recon", "KL"], ...
    Info = ["Epoch", "Loss"], ...
    XLabel = "Iteration");
end

function stop = stop_requested(monitor)
  if ~isempty(monitor.gui_monitor)
    % Check for stop from GUI
    stop = monitor.gui_monitor.Stop;
  else
    % TODO: Is there a way to catch an interrupt signal?
    stop = false;
  end
end

function monitor = update_monitor(monitor)
  % Update GUI if it exists
  if ~isempty(monitor.gui_monitor)
    recordMetrics(monitor.gui_monitor, ...
      monitor.iteration, ...
      'Recon', monitor.losses.recon_loss, ...
      'KL', monitor.losses.kl_loss);
  
    updateInfo(monitor.gui_monitor, ...
      'Epoch', monitor.epoch, ...
      'Loss', monitor.losses.total_loss);
  end

  % Update console periodically
  if (monitor.console_update_counter > 0)
    monitor.console_update_counter = monitor.console_update_counter - 1;
  else
    % Reset counter
    monitor.console_update_counter = monitor.console_update_iterations - 1;

    % CSV format:
    % time, epoch, iteration, total loss, recon loss, KL loss
    csv_line = sprintf('%s, %d, %d, %f, %f, %f\n', ...
      datetime(), ...
      monitor.epoch, ...
      monitor.iteration, ...
      extractdata(monitor.losses.total_loss), ...
      extractdata(monitor.losses.recon_loss), ...
      extractdata(monitor.losses.kl_loss));
    
    % Write CSV to console
    fprintf('%s', csv_line);

    % Write CSV to file
    if ~isempty(monitor.training_csv_file)
      csv_file_id = [];
      try
        csv_file_id = fopen(monitor.training_csv_file, 'a');
        fwrite(csv_file_id, csv_line);
      catch ex
        fprintf('[%s] ERROR: Failed to write to CSV file: %s\n%s\n', ...
          datetime(), ...
          ex.identifier, ...
          ex.message);
        % TODO: Ignore this exception or do something else with it?
      end
  
      if ~isempty(csv_file_id)
        fclose(csv_file_id);
      end
    end
  end
end

function [validation_losses] = perform_validation(model_eval_cb, model, batch, training_params, monitor)
  % Get losses from evaluation function
  [validation_losses, ~, ~] = dlfeval(model_eval_cb, model, batch, training_params);

  % Display validation info
  fprintf('[%s] Validation loss: %f\n  Recon: %f\n  KL: %f\n', ...
    datetime(), ...
    extractdata(validation_losses.total_loss), ...
    extractdata(validation_losses.recon_loss), ...
    extractdata(validation_losses.kl_loss));

  % CSV format:
  % time, epoch, iteration, total loss, recon loss, KL loss
  csv_line = sprintf('%s, %d, %d, %f, %f, %f\n', ...
    datetime(), ...
    monitor.epoch, ...
    monitor.iteration, ...
    extractdata(monitor.losses.total_loss), ...
    extractdata(monitor.losses.recon_loss), ...
    extractdata(monitor.losses.kl_loss));

  % Write CSV to file
  if ~isempty(monitor.validation_csv_file)
    csv_file_id = [];
    try
      csv_file_id = fopen(monitor.validation_csv_file, 'a');
      fwrite(csv_file_id, csv_line);
    catch ex
      fprintf('[%s] ERROR: Failed to write to CSV file: %s\n%s\n', ...
        datetime(), ...
        ex.identifier, ...
        ex.message);
      % TODO: Ignore this exception or do something else with it?
    end

    if ~isempty(csv_file_id)
      fclose(csv_file_id);
    end
  end
end
