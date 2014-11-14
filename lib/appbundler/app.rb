require 'bundler'
require 'pp'

module Appbundler
  class App

    BINSTUB_FILE_VERSION=1

    attr_reader :app_root
    attr_reader :target_bin_dir

    def self.demo
      demo = new("/Users/ddeleo/oc/chef")

      knife = demo.executables.grep(/knife/).first
      puts demo.binstub(knife)
    end

    def initialize(app_root, target_bin_dir)
      @app_root = app_root
      @target_bin_dir = target_bin_dir
    end

    def write_executable_stubs
      executables_to_create = executables.map do |real_executable_path|
        basename = File.basename(real_executable_path)
        stub_path = File.join(target_bin_dir, basename)
        [real_executable_path, stub_path]
      end

      executables_to_create.each do |real_executable_path, stub_path|
        File.open(stub_path, "wb", 0755) do |f|
          f.write(binstub(real_executable_path))
        end
        if RUBY_PLATFORM =~ /mswin|mingw|windows/
          batch_wrapper_path = "#{stub_path}.bat"
          File.open(batch_wrapper_path, "wb", 0755) do |f|
            f.write(batchfile_stub)
          end
        end
      end

      executables_to_create
    end

    def name
      File.basename(app_root)
    end

    def gemfile_lock
      File.join(app_root, "Gemfile.lock")
    end

    def ruby
      Gem.ruby
    end

    def batchfile_stub
      ruby_relpath_windows = ruby_relative_path.gsub('/', '\\')
      <<-E
@ECHO OFF
"%~dp0\\#{ruby_relpath_windows}" "%~dpn0" %*
E
    end

    # Relative path from #target_bin_dir to #ruby. This is used to
    # generate batch files for windows in a way that the package can be
    # installed in a custom location. On Unix we don't support custom
    # install locations so this isn't needed.
    def ruby_relative_path
      ruby_pathname = Pathname.new(ruby)
      bindir_pathname = Pathname.new(target_bin_dir)
      ruby_pathname.relative_path_from(bindir_pathname).to_s
    end

    def shebang
      "#!#{ruby}\n"
    end

    # A specially formatted comment that documents the format version of the
    # binstub files we generate.
    #
    # This comment should be unusual enough that we can reliably (enough)
    # detect whether a binstub was created by Appbundler and parse it to learn
    # what version of the format it uses. If we ever need to support reading or
    # mutating existing binstubs, we'll know what file version we're starting
    # with.
    def file_format_comment
      "#--APP_BUNDLER_BINSTUB_FORMAT_VERSION=#{BINSTUB_FILE_VERSION}--\n"
    end

    # Ruby code (as a string) that clears GEM_HOME and GEM_PATH environment
    # variables. In an omnibus context, this is important so users can use
    # things like rvm without accidentally pointing the app at rvm's
    # ruby and gems.
    #
    # Environment sanitization can be skipped by setting the
    # APPBUNDLER_ALLOW_RVM environment variable to "true". This feature
    # exists to make tests run correctly on travis.ci (which uses rvm).
    def env_sanitizer
      %Q{ENV["GEM_HOME"] = ENV["GEM_PATH"] = nil unless ENV["APPBUNDLER_ALLOW_RVM"] == "true"}
    end

    def runtime_activate
      @runtime_activate ||= begin
        statements = runtime_dep_specs.map {|s| %Q|gem "#{s.name}", "= #{s.version}"|}
        activate_code = ""
        activate_code << env_sanitizer << "\n"
        activate_code << statements.join("\n") << "\n"
        activate_code
      end
    end

    def binstub(bin_file)
      shebang + file_format_comment + runtime_activate + load_statement_for(bin_file)
    end

    def load_statement_for(bin_file)
      <<-E
bin_dir = File.dirname(__FILE__)
if File.symlink?(__FILE__)
  bin_dir = File.dirname(File.readlink(__FILE__))
end

$:.unshift(File.expand_path("#{relative_app_lib_dir}", bin_dir))
Kernel.load(File.expand_path('#{relative_bin_file(bin_file)}', bin_dir))
E
    end

    def relative_bin_file(bin_file)
      bin_file_pathname = Pathname.new(bin_file)
      bindir_pathname = Pathname.new(target_bin_dir)
      bin_file_pathname.relative_path_from(bindir_pathname).to_s
    end

    def executables
      if available_gemspecs.empty?
        bin_dir_glob = File.join(app_root, "bin", "*")
        Dir[bin_dir_glob]
      else
        executables_for_gemspec
      end
    end

    def available_gemspecs
      @available_gemspecs ||= Dir[File.join(app_root, "#{name}*.gemspec")]
    end

    def sorted_gemspecs
      # Gemspecs are sorted by the length of their name
      # Find all specs in app_root.
      specs = available_gemspecs.sort do |a, b|
        b.length <=> a.length
      end

      # Lazily load gemspecs, starting with the ones that are most
      # specific
      Enumerator.new do |y|
        specs.each do |spec_path|
          spec = nil
          Dir.chdir(app_root) do
            spec = Gem::Specification::load(spec_path)
          end
          y << spec
        end
      end
    end

    def most_specific_gemspec
      # The most specific gemspec is the longest gemspec that matches the 
      # current platform. The reason for this is that the Chef projects that
      # have platform specific gemspecs follow the pattern app.gemspec and
      # app-arch-platform.gemspec. The platform specific gemspec always
      # contains the generic gemspec, so we just need to find the gemspec
      # with the longest path that also matches the current platform.
      @most_specific_gemspec ||= sorted_gemspecs.detect do |spec|
        Gem::Platform.match(spec.platform)
      end
    end

    def executables_for_gemspec
      # Returns the executable for the most specific gemspec
      most_specific_gemspec.executables.map do |e|
        File.join(app_root, most_specific_gemspec.bindir, e)
      end
    end

    def relative_app_lib_dir
      lib_dir_pathname = Pathname.new(app_lib_dir)
      bindir_pathname = Pathname.new(target_bin_dir)
      lib_dir_pathname.relative_path_from(bindir_pathname).to_s
    end

    def app_lib_dir
      File.join(app_root, "lib")
    end

    def runtime_dep_specs
      add_dependencies_from(app_spec)
    end

    def app_dependency_names
      @app_dependency_names ||= app_spec.dependencies.map(&:name)
    end

    def app_spec
      spec_for(name)
    end

    def gemfile_lock_specs
      parsed_gemfile_lock.specs
    end

    def parsed_gemfile_lock
      @parsed_gemfile_lock ||= Bundler::LockfileParser.new(IO.read(gemfile_lock))
    end

    private

    def add_dependencies_from(spec, collected_deps=[])
      spec.dependencies.each do |dep|
        next if collected_deps.any? {|s| s.name == dep.name }
        next_spec = spec_for(dep.name)
        collected_deps << next_spec
        add_dependencies_from(next_spec, collected_deps)
      end
      collected_deps
    end

    def spec_for(dep_name)
      gemfile_lock_specs.find {|s| s.name == dep_name } or raise "No spec #{dep_name}"
    end
  end
end
