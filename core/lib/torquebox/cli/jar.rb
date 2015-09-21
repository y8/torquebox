# Copyright 2014 Red Hat, Inc, and individual contributors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'fileutils'
require 'pathname'
require 'rbconfig'
require 'tmpdir'
require 'torquebox-core'

module TorqueBox
  class CLI
    class Jar

      DEFAULT_INIT = "require 'torquebox-core'; \
        TorqueBox::CLI::Archive.new(ARGV).run;"

      attr_reader :logger, :composer

      def initialize
        @logger = org.projectodd.wunderboss.WunderBoss.logger('TorqueBox')
        @composer = TorqueBox::Composers::JarComposer.new(@logger)
      end

      def usage_parameters
        "<app-path> [options]"
      end

      def available_options
        [{
           :name => :jar_name,
           :switch => '--name NAME',
           :description => "Name and the path of the jar file (default: #{composer.jar_name})"
         },
         {
           :name => :include_jruby,
           :switch => '--[no-]include-jruby',
           :description => "Include JRuby in the jar (default: #{composer.include_jruby})"
         },
         {
           :name => :bundle_gems,
           :switch => '--[no-]bundle-gems',
           :description => "Bundle gem dependencies in the jar (default: #{composer.bundle_gems})"
         },
         {
           :name => :bundle_without,
           :switch => '--bundle-without GROUPS',
           :description => "Bundler groups to skip (default: #{composer.bundle_without})",
           :type => Array
         },
         {
           :name => :main,
           :switch => '--main MAIN',
           :description => 'File to require to bootstrap the application (if not given, assumes a web app)'
         },
         {
           :name => :exclude,
           :switch => '--exclude EXCLUDES',
           :description => 'File paths to exclude from bundled jar',
           :type => Array
         }]
      end

      def setup_parser(parser, options)
        available_options.each do |opt|
          parser_options = opt.values_at(:short, :switch, :type, :description)
          parser_options.compact!

          option_name = opt[:name]

          parser.on(*parser_options) do |arg|
            options[option_name] = arg
          end
        end

        parser.on('--envvar KEY=VALUE',
                  'Specify an environment variable to set before running the app') do |arg|
          key, value = arg.split('=')

          if key.nil? || value.nil?
            $stderr.puts "Error: Environment variables must be separated by '='"
            exit 1
          end

          options[:env_variables] ||= {}
          options[:env_variables][key] = value
        end
      end

      def run(argv, options)
        app_path = argv.shift

        if app_path
          composer.app_path = app_path
        end

        logger.debug "Creating jar in {} with options {}", composer.app_path,
                                                             options.inspect

        options.each do |name, value|
          if composer.respond_to? name
            composer.send(:"#{name}=", value)
          else
            $stderr.puts "Error: Unknown jar composer option: #{name}"
            exit 2
          end
        end

        composer.write_jar
      ensure
        composer.cleanup
      end
    end
  end
end

TorqueBox::CLI.register_extension('jar', TorqueBox::CLI::Jar.new,
                                  'Create an executable jar from an application')
