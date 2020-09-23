# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/newrelic-ruby-agent/blob/main/LICENSE for complete details.

DependencyDetection.defer do
  @name = :sidekiq

  depends_on do
    defined?(::Sidekiq) && !NewRelic::Agent.config[:disable_sidekiq]
  end

  executes do
    ::NewRelic::Agent.logger.info 'Installing Sidekiq instrumentation'
  end

  executes do
    module NewRelic::SidekiqInstrumentation
      class Server
        include NewRelic::Agent::Instrumentation::ControllerInstrumentation

        # Client middleware has additional parameters, and our tests use the
        # middleware client-side to work inline.
        def call(worker, msg, queue, *_)
          trace_args = if worker.respond_to?(:newrelic_trace_args)
            worker.newrelic_trace_args(msg, queue)
          else
            self.class.default_trace_args(msg)
          end

          ::NewRelic::Agent.logger.info "Server NewRelic::NEWRELIC_KEY: #{NewRelic:NEWRELIC_KEY}"
          trace_headers = if worker.class.name == 'Sidekiq::Batch::Callback'
            ::NewRelic::Agent.logger.info 'getting trace_headers from callback class'
            ::NewRelic::Agent.logger.info "msg: #{msg}"
            ::NewRelic::Agent.logger.info "trace_args: #{trace_args}"
            msg.delete(NewRelic::NEWRELIC_KEY)
          else
            ::NewRelic::Agent.logger.info "getting trace_headers from #{worker.class.name}"
            ::NewRelic::Agent.logger.info "msg: #{msg}"
            ::NewRelic::Agent.logger.info "trace_args: #{trace_args}"
            msg.delete(NewRelic::NEWRELIC_KEY)
          end

          if trace_headers.nil?
            ::NewRelic::Agent.logger.info "no trace_headers found in msg #{msg}"
          end
          ::NewRelic::Agent.logger.info "trace_headers: #{trace_headers}"

          perform_action_with_newrelic_trace(trace_args) do
            NewRelic::Agent::Transaction.merge_untrusted_agent_attributes(msg['args'], :'job.sidekiq.args',
                                                                          NewRelic::Agent::AttributeFilter::DST_NONE)

            ::NewRelic::Agent::DistributedTracing::accept_distributed_trace_headers(trace_headers, "Other") if ::NewRelic::Agent.config[:'distributed_tracing.enabled']
            yield
          end
        end

        def self.default_trace_args(msg)
          {
            :name => 'perform',
            :class_name => msg['class'],
            :category => 'OtherTransaction/SidekiqJob'
          }
        end
      end
      class Client
        def call(_worker_class, job, *_)
          ::NewRelic::Agent.logger.info "Client class:#{_worker_class}, job: #{job}"
          ::NewRelic::Agent.logger.info "Client NewRelic::NEWRELIC_KEY: #{NewRelic::NEWRELIC_KEY}"
          ::NewRelic::Agent.logger.info "Client NEWRELIC_KEY before anything #{job[NewRelic::NEWRELIC_KEY]}"
          job[NewRelic::NEWRELIC_KEY] = distributed_tracing_headers if ::NewRelic::Agent.config[:'distributed_tracing.enabled']
          ::NewRelic::Agent.logger.info "Client NEWRELIC_KEY after #{job[NewRelic::NEWRELIC_KEY]}"
          yield
        end

        def distributed_tracing_headers
          headers = {}
          ::NewRelic::Agent::DistributedTracing.insert_distributed_trace_headers(headers)
          headers
        end
      end
    end

    class Sidekiq::Extensions::DelayedClass
      def newrelic_trace_args(msg, queue)
        (target, method_name, _args) = YAML.load(msg['args'][0])
        {
          :name => method_name,
          :class_name => target.name,
          :category => 'OtherTransaction/SidekiqJob'
        }
      rescue => e
        NewRelic::Agent.logger.error("Failure during deserializing YAML for Sidekiq::Extensions::DelayedClass", e)
        NewRelic::SidekiqInstrumentation::Server.default_trace_args(msg)
      end
    end

    Sidekiq.configure_client do |config|
      config.client_middleware do |chain|
        chain.add NewRelic::SidekiqInstrumentation::Client
      end
    end

    Sidekiq.configure_server do |config|
      config.client_middleware do |chain|
        chain.add NewRelic::SidekiqInstrumentation::Client
      end
      config.server_middleware do |chain|
        chain.add NewRelic::SidekiqInstrumentation::Server
      end

      if config.respond_to?(:error_handlers)
        config.error_handlers << Proc.new do |error, *_|
          NewRelic::Agent.notice_error(error)
        end
      end
    end
  end
end
