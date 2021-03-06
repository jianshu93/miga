# @package MiGA
# @license Artistic-2.0

require 'miga/project'
require 'miga/daemon/base'

##
# MiGA Daemons handling job submissions.
class MiGA::Daemon < MiGA::MiGA

  include MiGA::Daemon::Base

  ##
  # When was the last time a daemon for the MiGA::Project +project+ was seen
  # active? Returns Time.
  def self.last_alive(project)
    f = File.expand_path('daemon/alive', project.path)
    return nil unless File.exist? f
    Time.parse(File.read(f))
  end

  # Array of all spawned daemons.
  $_MIGA_DAEMON_LAIR = []

  # MiGA::Project in which the daemon is running.
  attr_reader :project
  # Options used to setup the daemon.
  attr_reader :options
  # Array of jobs next to be executed.
  attr_reader :jobs_to_run
  # Array of jobs currently running.
  attr_reader :jobs_running
  # Integer indicating the current iteration.
  attr_reader :loop_i

  ##
  # Initialize an unactive daemon for the MiGA::Project +project+. See #daemon
  # to wake the daemon.
  def initialize(project)
    $_MIGA_DAEMON_LAIR << self
    @project = project
    @runopts = JSON.parse(
          File.read(File.expand_path('daemon/daemon.json', project.path)),
          symbolize_names: true)
    @jobs_to_run = []
    @jobs_running = []
    @loop_i = -1
  end

  ##
  # When was the last time a daemon for the current project was seen active?
  # Returns Time.
  def last_alive
    MiGA::Daemon.last_alive project
  end

  ##
  # Returns Hash containing the default options for the daemon.
  def default_options
    { dir_mode: :normal, dir: File.expand_path('daemon', project.path),
      multiple: false, log_output: true }
  end

  ##
  # Launches the +task+ with options +opts+ (as command-line arguments).
  # Supported tasks include: start, stop, restart, status.
  def daemon(task, opts=[])
    options = default_options
    opts.unshift(task)
    options[:ARGV] = opts
    Daemons.run_proc("MiGA:#{project.name}", options) do
      loop { break unless in_loop }
    end
  end

  ##
  # Tell the world that you're alive.
  def declare_alive
    f = File.open(File.expand_path('daemon/alive', project.path), 'w')
    f.print Time.now.to_s
    f.close
  end

  ##
  # Report status in a JSON file.
  def report_status
    f = File.open(File.expand_path('daemon/status.json', project.path), 'w')
    f.print JSON.pretty_generate(
      jobs_running: @jobs_running, jobs_to_run: @jobs_to_run)
    f.close
  end

  ##
  # Load the status of a previous instance.
  def load_status
    f_path = File.expand_path('daemon/status.json', project.path)
    return unless File.size? f_path
    say 'Loading previous status in daemon/status.json:'
    status = JSON.parse(File.read(f_path), symbolize_names: true)
    status.keys.each do |i|
      status[i].map! do |j|
        j.tap do |k|
          unless k[:ds].nil? or k[:ds_name] == 'miga-project'
            k[:ds] = project.dataset(k[:ds_name])
          end
          k[:job] = k[:job].to_sym unless k[:job].nil?
        end
      end
    end
    @jobs_running = status[:jobs_running]
    @jobs_to_run  = status[:jobs_to_run]
    say "- jobs left running: #{@jobs_running.size}"
    purge!
    say "- jobs running: #{@jobs_running.size}"
    say "- jobs to run: #{@jobs_to_run.size}"
  end

  ##
  # Traverse datasets
  def check_datasets
    project.each_dataset do |n, ds|
      if ds.nil?
        say "Warning: Dataset #{n} listed but not loaded, reloading project"
        project.load
      else
        to_run = ds.next_preprocessing(true)
        queue_job(to_run, ds) unless to_run.nil?
      end
    end
  end

  ##
  # Check if all reference datasets are pre-processed. If yes, check the
  # project-level tasks
  def check_project
    return if project.dataset_names.empty?
    return unless project.done_preprocessing?(false)
    to_run = project.next_distances(true)
    to_run = project.next_inclade(true) if to_run.nil?
    queue_job(to_run) unless to_run.nil?
  end

  ##
  # Add the task to the internal queue with symbol key +job+. If the task is
  # dataset-specific, +ds+ specifies the dataset. To submit jobs to the
  # scheduler (or to bash) see #flush!.
  def queue_job(job, ds=nil)
    return nil unless get_job(job, ds).nil?
    ds_name = (ds.nil? ? 'miga-project' : ds.name)
    say 'Queueing %s:%s' % [ds_name, job]
    vars = {
      'PROJECT' => project.path,
      'RUNTYPE' => runopts(:type),
      'CORES'   => ppn,
      'MIGA'    => MiGA::MiGA.root_path
    }
    vars['DATASET'] = ds.name unless ds.nil?
    log_dir = File.expand_path("daemon/#{job}", project.path)
    Dir.mkdir(log_dir) unless Dir.exist? log_dir
    task_name = "#{project.metadata[:name][0..9]}:#{job}:#{ds_name}"
    to_run = {ds: ds, ds_name: ds_name, job: job, task_name: task_name,
      cmd: sprintf(runopts(:cmd),
        # 1: script
        MiGA::MiGA.script_path(job, miga:vars['MIGA'], project:project),
        # 2: vars
        vars.keys.map { |k| sprintf(runopts(:var), k, vars[k]) }.
          join(runopts(:varsep)),
        # 3: CPUs
        ppn,
        # 4: log file
        File.expand_path("#{ds_name}.log", log_dir),
        # 5: task name
        task_name)}
    @jobs_to_run << to_run
  end

  ##
  # Get the taks with key symbol +job+ in dataset +ds+. For project-wide tasks
  # let +ds+ be nil.
  def get_job(job, ds = nil)
    (jobs_to_run + jobs_running).find do |j|
      if ds.nil?
        j[:ds].nil? and j[:job] == job
      else
        (! j[:ds].nil?) and j[:ds].name == ds.name and j[:job] == job
      end
    end
  end

  ##
  # Remove finished jobs from the internal queue and launch as many as
  # possible respecting #maxjobs.
  def flush!
    # Check for finished jobs
    @jobs_running.select! do |job|
      r = (job[:ds].nil? ? project : job[:ds]).add_result(job[:job], false)
      say "Completed pid:#{job[:pid]} for #{job[:task_name]}." unless r.nil?
      r.nil?
    end
    # Avoid single datasets hogging resources
    @jobs_to_run.rotate! rand(jobs_to_run.size)
    # Launch as many +jobs_to_run+ as possible
    while jobs_running.size < maxjobs
      break if jobs_to_run.empty?
      launch_job @jobs_to_run.shift
    end
  end

  ##
  # Remove dead jobs.
  def purge!
    @jobs_running.select! do |job|
      `#{sprintf(runopts(:alive), job[:pid])}`.chomp.to_i == 1
    end
  end

  ##
  # Run one loop step. Returns a Boolean indicating if the loop should continue.
  def in_loop
    declare_alive
    project.load
    if loop_i == -1
      say '-----------------------------------'
      say 'MiGA:%s launched.' % project.name
      say '-----------------------------------'
      load_status
      @loop_i = 0
    end
    @loop_i += 1
    check_datasets
    check_project
    if shutdown_when_done? and jobs_running.size + jobs_to_run.size == 0
      say 'Nothing else to do, shutting down.'
      return false
    end
    flush!
    if loop_i==4
      say 'Housekeeping for sanity'
      @loop_i = 0
      purge!
    end
    report_status
    sleep(latency)
    true
  end

  ##
  # Send a datestamped message to the log.
  def say(*opts)
    print "[#{Time.new.inspect}] ", *opts, "\n"
  end

  ##
  # Terminates a daemon.
  def terminate
    say 'Terminating daemon...'
    report_status
    k = runopts(:kill)
    @jobs_running.each do |i|
      `#{k % i[:pid]}`
      puts "Terminating pid:#{i[:pid]} for #{i[:task_name]}"
    end
    f = File.expand_path('daemon/alive', project.path)
    File.unlink(f) if File.exist? f
  end

  private

    def launch_job(job)
      # Execute job
      if runopts(:type) == 'bash'
        # Local job
        job[:pid] = spawn job[:cmd]
        Process.detach job[:pid] unless [nil, '', 0].include?(job[:pid])
      else
        # Schedule cluster job
        job[:pid] = `#{job[:cmd]}`.chomp
      end

      # Check if registered
      if [nil, '', 0].include? job[:pid]
        job[:pid] = nil
        @jobs_to_run << job
        say "Unsuccessful #{job[:task_name]}, rescheduling."
      else
        @jobs_running << job
        say "Spawned pid:#{job[:pid]} for #{job[:task_name]}."
      end
    end
end
