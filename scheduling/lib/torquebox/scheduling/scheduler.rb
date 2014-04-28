module TorqueBox
  module Scheduling
    class Scheduler
      include TorqueBox::OptionUtils

      attr_accessor :scheduling_component

      WB = org.projectodd.wunderboss.WunderBoss
      WBScheduling = org.projectodd.wunderboss.scheduling.Scheduling

      def schedule(id, spec, &block)
        validate_options(spec, opts_to_set(WBScheduling::ScheduleOption))
        spec = coerce_schedule_options(spec)
        scheduling_component.schedule(id.to_s, block,
                                      extract_options(spec, WBScheduling::ScheduleOption))
      end

      def unschedule(id)
        scheduling_component.unschedule(id.to_s)
      end

      def start
        @scheduling_component.start
      end

      def stop
        @scheduling_component.stop
      end

      protected

      def initialize(name, options={})
        @logger = WB.logger('TorqueBox::Scheduling::Scheduler')
        validate_options(options, opts_to_set(WBScheduling::CreateOption))
        create_options = extract_options(options, WBScheduling::CreateOption)
        comp = WB.find_or_create_component(WBScheduling.java_class, name,
                                           create_options)
        @logger.debugf("TorqueBox::Scheduling::Scheduler '%s' has component %s",
                       name, comp)
        @scheduling_component = comp
        at_exit { stop }
      end

      def coerce_schedule_options(options)
        options.clone.merge(options) do |k,v|
          # ActiveSupport's durations use seconds as the base unit, so
          # we have to detect that and convert to ms
          v = v.in_milliseconds if defined?(ActiveSupport::Duration) && v.is_a?(ActiveSupport::Duration)

          v = as_date(v) if [:at, :until].include?(k)

          v = !!v if k == :singleton

          v.to_java
        end
      end

      def as_date(val)
        if val.is_a?(Integer)
          Time.at(val)
        else
          val
        end
      end

    end
  end
end