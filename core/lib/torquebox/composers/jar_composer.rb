require 'fileutils'
require 'pathname'
require 'rbconfig'
require 'tmpdir'

module TorqueBox
  module Composers
    class JarComposer
      DEFAULT_INIT = "require 'torquebox-core';\
        TorqueBox::CLI::Archive.new(ARGV).run;"

      attr_reader :logger, :temp_dir
      attr_reader :jar_path, :app_path, :class_path, :env_variables

      attr_accessor :include_jruby, :bundle_gems, :bundle_without, :bundle_local,
                    :rackup_file, :classpath, :destination

      attr_accessor :exclude, :main

      def initialize(logger)
        @logger = logger

        self.app_path = Dir.pwd
        self.jar_path = app_path.join("#{@app_path.basename}.jar")

        self.include_jruby = true

        self.bundle_gems = true
        self.bundle_local = false
        self.bundle_without = %W(development test assets)

        self.rackup_file = 'config.ru'
        self.exclude = []

        @classpath = []
        @env_variables = {}
        @temp_dir = Pathname.new(Dir.mktmpdir)
      end

      def jar_builder
        @jar_builder ||= org.torquebox.core.JarBuilder.new.tap do |builder|
          builder.add_manifest_attribute('Main-Class', 'org.torquebox.core.TorqueBoxMain')
          builder.add_string(TorqueBox::JAR_MARKER, '')
        end
      end

      def cleanup
        return unless @temp_dir && @temp_dir.exist?

        logger.trace "Cleaning temporary files"

        FileUtils.remove_entry_secure @temp_dir
      end

      def app_path=(new_path)
        @app_path = Pathname.new(new_path).expand_path.freeze
      end

      def jar_path=(new_path)
        @jar_path = Pathname.new(new_path).expand_path.freeze
      end

      def env_variables=(new_variables)
        @env_variables = env_variables.merge(new_variables)
      end

      def jar_name
        @jar_path.basename
      end

      def destination=(_new_path)
        logger.warn '--destination is deprecated, use --name with path instead'
      end

      def write_jar
        add_torquebox_files
        add_jruby_files
        add_app_files
        add_bundled_gems
        add_app_properties

        if jar_path.exist?
          logger.info("Removing {}", jar_path)
          FileUtils.remove_entry_secure jar_path
        end

        logger.info("Writing {}", jar_path)

        jar_builder.create(jar_path.to_s)
        jar_path
      end

      def add_torquebox_files
        TorqueBox::Jars.list.each do |jar|
          if File.basename(jar) =~ /^wunderboss-(rack|ruby).*?\.jar$/
            add_jar jar
          else
            logger.debug "Shading jar {}", jar
            jar_builder.shade_jar(jar)
          end
        end
      end

      def add_jruby_files
        return unless include_jruby

        logger.trace "Adding JRuby files to jar..."

        rb_config = RbConfig::CONFIG

        jruby_dir = rb_config["prefix"]
        jruby_lib_dir = rb_config["libdir"]
        jruby_bin_dir = rb_config["bindir"]

        # Add only files from the jruby root
        add_files :source => jruby_dir,
                  :destination => "jruby",
                  :pattern => "*"

        # Add all contents of the jruby lib, excluding jruby.jar and shared gems
        add_files :source => jruby_lib_dir,
                  :destination => "jruby/lib",
                  :pattern => "**/*",
                  :exclude => ["jruby.jar", "ruby/gems/shared"]

        # Add only files from the bin
        add_files :source => jruby_bin_dir,
                  :destination => "jruby/bin",
                  :pattern => "*"

        # Add jruby.jar
        add_jar "#{jruby_lib_dir}/jruby.jar"
      end

      def add_app_files
        logger.trace "Adding application files to jar..."

        defaults = [%r{^/[^/]*\.(jar|war)}]

        app_exclude = exclude.each_with_object(defaults) do |rule, memo|
          memo << Regexp.new("^#{e}")
        end

        add_files :source => app_path.to_s,
                  :destination => 'app',
                  :pattern => '**/{*,.*manifest*}',
                  :exclude => app_exclude
      end

      # Add all app the dependencies from the Gemfile to the jar. This will
      # force bundler to make new `vendor/bundle` in the temporary location and
      # then it will add the contents of the `vendor/bundle` to the jar.
      #
      # There few things to consider:
      #
      #   * That's a bad idea to pack jar when `Gemfile.lock` is not present.
      #     This is addressed by showing warning to the user, that dependencies
      #     will be build from the current state of the rubygems.
      #
      #   * User might want to pack the gems without fetching them from the
      #     remote sources. Before it was forced, now it can be done by
      #     explicitly passing the `--bundle-local` option.
      #
      #   * User might already have the `vendor/bundle`. This is addressed by
      #     showing the warning that contents of the `vendor/bundle` will be
      #     added to jar as-is.
      #
      #   * User might have custom `vendor/bundle` location in global or local
      #     .bundle/config. This is not addressed currently.
      #
      #   * `.bundle/config` is copied to the jar, this might lead to the erros
      #     if config is depend on the current working directory.
      #
      #   * If `BUNDLE_GEMFILE` is set, bundler will use the folder where the
      #     `Gemfile` is located to resolve `Gemfile.lock` and `vendor/bundle`.
      #     This is addressed by setting `BUNDLE_GEMFILE` to nil on the jar
      #     boot, so default `vendor/bundle` location is used by the bundler.
      #     This might interfere with `.bundle/config` and lead to the same
      #     issues as listed above.
      def add_bundled_gems
        return unless bundle_gems

        if bundle_local
          logger.trace 'Adding bundler filer to jar locally...'
        else
          logger.trace 'Adding bundler files to jar...'
        end

        require 'bundler'
        begin
          gemfile_path, lockfile_path = nil

          # Execute Bundler commands in the app_path, not in the Dir.pwd
          Bundler::SharedHelpers.chdir app_path do
            # No need to check ENV['BUNDLE_GEMFILE'], because Bundler will
            # take care of that
            gemfile_path = Bundler.default_gemfile
            lockfile_path = Bundler.default_lockfile
          end
        rescue Bundler::GemfileNotFound
          logger.warn 'No Gemfile found - skipping gem dependencies'
          return {}
        end

        # We need gemfile_root to properly locate the `vendor/bundle`
        gemfile_root = gemfile_path.parent
        vendor_cache_path = gemfile_root.join('vendor/cache')
        vendor_bundle_path = gemfile_root.join('vendor/bundle')

        unless lockfile_path.exist?
          logger.warn 'No Gemfile.lock found — this might lead to unexpected \
          dependency tree, please consider running `bundle install` to resolve \
          and lock dependencies.'
        end

        exclude_registed_jars = TorqueBox::Jars.list.map { |j| File.basename(j) }
        bundle_source = temp_dir

        # No need to run bundler at all. Just copy the contents of the
        # `vendor/bundle` to the jar
        if vendor_bundle_path.exist?
          logger.info 'Using existing `vendor/bundle`. Make sure that your \
          dependencies is up to date.'

          bundle_source = vendor_bundle_path
        else
          vendor_bundle_gems :lockfile_exist => lockfile_path.exist?
        end

        add_files :source => bundle_source.to_s,
                  :destination => 'app/vendor/bundle',
                  :pattern => '/{**/*,.bundle/**/*}',
                  :exclude => exclude_registed_jars

        copy_bundler_gem
      end

      def copy_bundler_gem
        # Copy bundler gem
        bundler_pattern = "/**/bundler-#{Bundler::VERSION}{*,/**/*}"

        Gem.path.each do |gem_path|
          add_files :source => gem_path,
                    :destination => 'jruby/lib/ruby/gems/shared',
                    :pattern => bundler_pattern
        end
      end

      def vendor_bundle_gems(options)
        logger.trace 'Running the `bundle install` in {}', temp_dir

        original_path = Bundler.settings[:path]
        original_cache = Bundler.settings[:app_cache_path]
        install_options = %W(--path #{temp_dir} --no-cache --no-prune)

        if options[:lockfile_exist]
          install_options << %W(--frozen)
        end

        if bundle_without.any?
          install_options << %W(--without #{bundle_without.join(' ')})
        end

        if bundle_local
          install_options << %W(--local)
        end

        install_options.flatten!

        eval_in_new_ruby <<-EOS
          require 'bundler/cli'
          Bundler::CLI.start(['install'] + #{install_options.inspect})
        EOS
      ensure
        Bundler.settings[:path] = original_path
      end

      def add_files(options)
        source_dir = options[:source].chomp('/')
        source_dir << '/'

        destination_dir = options[:destination]
        pattern = options[:pattern]

        search_pattern = source_dir + pattern

        excludes = options[:exclude] || []
        excludes.compact!
        excludes.flatten!
        excludes.uniq!

        excludes_regexp = excludes.select { |rule| rule.is_a? Regexp }
        excludes -= excludes_regexp

        # Remove source dir from the file_path, and return a hash where
        # key is relative path, and value is absolute
        files = Dir.glob(search_pattern).each_with_object({}) do |path, memo|
          relative_path = path.sub(/\A#{source_dir}/, '')
          memo[relative_path] = path
        end

        # Remove files if they contains string from exclude list
        excludes.each do |rule|
          files.delete_if { |relative, absolute| relative.include? rule }
        end

        # Remove files if they match regexp
        excludes_regexp.each do |rule|
          files.delete_if { |relative, absolute| relative.match rule }
        end

        logger.trace "Adding {} files from {} to {} ({})", files.size, source_dir,
                                                           destination_dir, pattern

        if destination_dir
          # Append destination_dir to the relative path, so foo/bar, becomes
          # <destination_dir>/foo/bar
          files.each_pair do |relative, absolute|
            path_in_jar = File.join(destination_dir, relative)
            jar_builder.add_file path_in_jar, absolute
          end
        else
          files.each_pair do |relative, absolute|
            jar_builder.add_file relative, absolute
          end
        end
      end

      def eval_in_new_ruby(script)
        # Copy our environment to the new Ruby runtime
        config = org.jruby.RubyInstanceConfig.new
        config.environment = ENV
        # Execute the ruby in the app path, not in the current working directory
        config.current_directory = app_path.to_s

        ruby = org.jruby.Ruby.new_instance(config)

        unless %W(DEBUG TRACE).include?(TorqueBox::Logger.log_level)
          dev_null = PLATFORM =~ /mswin/ ? 'NUL' : '/dev/null'
          ruby.evalScriptlet("$stdout = File.open('#{dev_null}', 'w')")
        end

        ruby.evalScriptlet(script)
      end

      # Add a jar file to the composed jar
      def add_jar(jar)
        logger.debug "Adding jar {}", jar

        jar_name = "jars/#{File.basename(jar)}"
        classpath << "${extract_root}/#{jar_name}"

        jar_builder.add_file(jar_name.to_s, jar.to_s)
      end

      def add_app_properties
        jar_builder.add_string("META-INF/app.properties", app_properties)
      end

      def app_init
        init = DEFAULT_INIT

        if main
          init = "ENV['TORQUEBOX_MAIN'] = '#{main}'; #{init}"
        end

        init = "ENV['TORQUEBOX_RACKUP'] = '#{rackup_file}'; #{init}"

        init
      end

      def app_properties
        env_config = env_variables.map do |key, value|
          "ENV['#{key}'] ||= '#{value}';"
        end

        env_string = env_config.join(' ')
        classpath_string = classpath.join(':')

        <<-EOS
language=ruby
extract_paths=app/:jruby/:jars/
root=${extract_root}/app
classpath=#{classpath_string}
init=ENV['BUNDLE_GEMFILE'] = nil; \
#{env_string} \
require "bundler/setup"; \
#{app_init}; \
require "torquebox/spec_helpers"; \
TorqueBox::SpecHelpers.booted
        EOS
      end
    end
  end
end
