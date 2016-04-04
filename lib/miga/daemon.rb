# @package MiGA
# @license Artistic-2.0

require "miga/project"
require "daemons"
require "date"

##
# MiGA Daemons handling job submissions.
class MiGA::Daemon < MiGA::MiGA
  
  ##
  # When was the last time a daemon for the MiGA::Project +project+ was seen
  # active? Returns DateTime.
  def self.last_alive(project)
    f = File.expand_path("daemon/alive", project.path)
    return nil unless File.size? f
    DateTime.parse(File.read(f))
  end
  
  # MiGA::Project in which the daemon is running.
  attr_reader :project
  # Options used to setup the daemon.
  attr_reader :options
  # Array of jobs next to be executed.
  attr_reader :jobs_to_run
  # Array of jobs currently running.
  attr_reader :jobs_running

  ##
  # Initialize an unactive daemon for the MiGA::Project +project+. See #daemon
  # to wake the daemon.
  def initialize(project)
    @project = project
    @runopts = JSON.parse(
      File.read(File.expand_path("daemon/daemon.json", project.path)),
        {:symbolize_names=>true})
    @jobs_to_run = []
    @jobs_running = []
  end

  ##
  # When was the last time a daemon for the current project was seen active?
  # Returns DateTime.
  def last_alive
    MiGA::Daemon.last_alive project
  end

  ##
  # Returns Hash containing the default options for the daemon.
  def default_options
    { dir_mode: :normal, dir: File.expand_path("daemon", project.path),
      multiple: false, log_output: true }
  end

  ##
  # Set/get #options, where +k+ is the Symbol of the option and +v+ is the value
  # (or nil to use as getter). Returns new value.
  def runopts(k, v=nil)
    k = k.to_sym
    unless v.nil?
      v = v.to_i if [:latency, :maxjobs, :ppn].include? k
      raise "Daemon's #{k} cannot be set to zero." if
        v.is_a? Integer and v==0
      @runopts[k] = v
    end
    @runopts[k]
  end

  ##
  # Returns Integer indicating the number of seconds to sleep between checks.
  def latency() runopts(:latency) ; end

  ##
  # Returns Integer indicating the maximum number of concurrent jobs to run.
  def maxjobs() runopts(:maxjobs) ; end

  ##
  # Returns Integer indicating the number of CPUs per job.
  def ppn() runopts(:ppn) ; end

  ##
  # Initializes the daemon.
  def start() daemon("start") ; end

  ##
  # Stops the daemon.
  def stop() daemon("stop") ; end

  ##
  # Restarts the daemon.
  def restart() daemon("restart") ; end

  ##
  # Returns the status of the daemon.
  def status() daemon("status") ; end

  ##
  # Launches the +task+ with options +opts+ (as command-line arguments).
  # Supported tasks include: start, stop, restart, status.
  def daemon(task, opts=[])
    options = default_options
    opts.unshift(task)
    options[:ARGV] = opts
    Daemons.run_proc("MiGA:#{project.name}", options) do
      say "-----------------------------------"
      say "MiGA:#{project.name} launched."
      say "-----------------------------------"
      loop_i = 0
      loop do
        loop_i += 1
        declare_alive
        traverse_datasets
        check_project
        flush!
        if loop_i==12
          say "Housekeeping for sanity"
          loop_i = 0
          purge!
          project.load
        end
        sleep(latency)
      end
    end
  end

  ##
  # Tell the world that you're alive
  def declare_alive
    f = File.open(File.expand_path("daemon/alive", project.path), "w")
    f.print Time.now.to_s
    f.close
  end

  ##
  # Traverse datasets
  def check_datasets
    project.each_dataset do |ds|
      to_run = ds.next_preprocessing(true)
      queue_job(to_run, ds) unless to_run.nil?
    end
  end

  ##
  # Check if all reference datasets are pre-processed. If yes, check the
  # project-level tasks
  def check_project
    if project.done_preprocessing?(false)
      to_run = project.next_distances(true)
      to_run = project.next_inclade(true) if to_run.nil?
      queue_job(to_run) unless to_run.nil?
    end
  end
  
  ##
  # Add the task to the internal queue with symbol key +job+. If the task is
  # dataset-specific, +ds+ specifies the dataset. To submit jobs to the
  # scheduler (or to bash) see #flush!.
  def queue_job(job, ds=nil)
    return nil unless get_job(job, ds).nil?
    ds_name = (ds.nil? ? "miga-project" : ds.name)
    say "Queueing ", ds_name, ":#{job}"
    vars = { "PROJECT"=>project.path, "RUNTYPE"=>runopts(:type),
      "CORES"=>ppn, "MIGA"=>MiGA::MiGA.root_path }
    vars["DATASET"] = ds.name unless ds.nil?
    log_dir = File.expand_path("daemon/#{job}", project.path)
    Dir.mkdir(log_dir) unless Dir.exist? log_dir
    task_name = "#{project.metadata[:name][0..9]}:#{job}:#{ds_name}"
    to_run = {ds: ds, job: job, task_name: task_name,
      cmd: sprintf(runopts(:cmd),
        # 1: script
        File.expand_path("scripts/#{job}.bash", vars["MIGA"]),
        # 2: vars
        vars.keys.map { |k|
	  sprintf(runopts(:var), k, vars[k])
	}.join(runopts(:varsep)),
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
  def get_job(job, ds=nil)
    (jobs_to_run + jobs_running).find do |j|
      if ds==nil
        j[:ds].nil? and j[:job]==job
      else
        (! j[:ds].nil?) and j[:ds].name==ds.name and j[:job]==job
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
      job = @jobs_to_run.shift
      if runopts(:type) == "bash"
        job[:pid] = spawn job[:cmd]
        Process.detach job[:pid]
      else
        job[:pid] = `#{job[:cmd]}`.chomp
      end
      @jobs_running << job
      say "Spawned pid:#{job[:pid]} for #{job[:task_name]}."
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
  # Send a datestamped message to the log.
  def say(*opts)
    print "[#{Time.new.inspect}] ", *opts, "\n"
  end

end
