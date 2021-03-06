# @package MiGA
# @license Artistic-2.0

require "miga/dataset"
require "miga/project/result"
require "miga/project/dataset"
require "miga/project/plugins"

##
# MiGA representation of a project.
class MiGA::Project < MiGA::MiGA
  
  include MiGA::Project::Result
  include MiGA::Project::Dataset
  include MiGA::Project::Plugins

  ##
  # Absolute path to the project folder.
  attr_reader :path
  
  ##
  # Information about the project as MiGA::Metadata.
  attr_reader :metadata

  ##
  # Create a new MiGA::Project at +path+, if it doesn't exist and +update+ is
  # false, or load an existing one.
  def initialize(path, update=false)
    @datasets = {}
    @path = File.absolute_path(path)
    self.create if not update and not Project.exist? self.path
    self.load if self.metadata.nil?
    self.load_plugins
    self.metadata[:type] = :mixed if type.nil?
    raise "Unrecognized project type: #{type}." if @@KNOWN_TYPES[type].nil?
  end

  ##
  # Create an empty project.
  def create
    unless MiGA::MiGA.initialized?
      raise "Impossible to create project in uninitialized MiGA."
    end
    dirs = [path] + @@FOLDERS.map{|d| "#{path}/#{d}" } +
      @@DATA_FOLDERS.map{ |d| "#{path}/data/#{d}"}
    dirs.each{ |d| Dir.mkdir(d) unless Dir.exist? d }
    @metadata = MiGA::Metadata.new(self.path + "/miga.project.json",
      {datasets: [], name: File.basename(path)})
    FileUtils.cp("#{ENV["MIGA_HOME"]}/.miga_daemon.json",
      "#{path}/daemon/daemon.json") unless
        File.exist? "#{path}/daemon/daemon.json"
    self.load
  end
  
  ##
  # Save any changes persistently.
  def save
    metadata.save
    self.load
  end
  
  ##
  # (Re-)load project data and metadata.
  def load
    @datasets = {}
    @dataset_names_hash = nil
    @metadata = MiGA::Metadata.load "#{path}/miga.project.json"
    raise "Couldn't find project metadata at #{path}" if metadata.nil?
  end
  
  ##
  # Name of the project.
  def name ; metadata[:name] ; end

  ##
  # Type of project.
  def type ; metadata[:type] ; end

  ##
  # Is this a clade project?
  def is_clade? ; type==:clade ; end

  ##
  # Is this a project for multi-organism datasets?
  def is_multi? ; @@KNOWN_TYPES[type][:multi] ; end
  
end
