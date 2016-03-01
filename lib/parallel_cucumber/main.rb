require 'parallel'

module ParallelCucumber
  class Main
    include ParallelCucumber::Helper::Utils

    def initialize(options)
      @options = options

      @logger = ParallelCucumber::CustomLogger.new(STDOUT)
      @logger.progname = 'Main'
      @logger.level = options[:debug] ? ParallelCucumber::CustomLogger::DEBUG : ParallelCucumber::CustomLogger::INFO
    end

    def run
      queue = Helper::Queue.new(@options[:queue_connection_params])
      @logger.debug("Connecting to Queue: #{@options[:queue_connection_params]}")

      unless queue.empty?
        @logger.error("Queue '#{queue.name}' is not empty")
        exit(1)
      end

      tests = []
      mm, ss = time_it do
        dry_run_report = Helper::Cucumber.dry_run_report(@options[:cucumber_options], @options[:cucumber_args])
        tests = Helper::Cucumber.parse_json_report(dry_run_report).keys
      end
      tests.shuffle!
      @logger.debug("Generating all tests took #{mm} minutes #{ss} seconds")

      @logger.info("Adding #{tests.count} tests to Queue")
      queue.enqueue(tests)

      if @options[:n] == 0
        @options[:n] = [1, @options[:env_variables].map { |_k, v| v.respond_to?(:size) && v.size }].flatten.max
        @logger.info("Inferred worker count #{@options[:n]} from env_variables option")
      end

      number_of_workers = [@options[:n], tests.count].min
      unless number_of_workers == @options[:n]
        @logger.info(<<-LOG)
          Number of workers was overridden to #{number_of_workers}.
          Was requested more workers (#{@options[:n]}) than tests (#{tests.count})".
        LOG
      end

      if (@options[:batch_size] - 1) * number_of_workers >= tests.count
        original_batch_size = @options[:batch_size]
        @options[:batch_size] = (tests.count.to_f / number_of_workers).ceil
        @logger.info(<<-LOG)
          Batch size was overridden to #{@options[:batch_size]}.
          Presumably it will be more optimal for #{tests.count} tests and #{number_of_workers} workers
          than #{original_batch_size}
        LOG
      end

      diff = []
      info = {}
      total_mm, total_ss = time_it do
        results = Parallel.map(0...number_of_workers, in_processes: number_of_workers) do |index|
          unless @options[:worker_delay] == 0
            @logger.info("Waiting #{@options[:worker_delay] * index} seconds before start")
            sleep(@options[:worker_delay] * index)
          end
          Worker.new(@options, index).start(env_for_worker(@options[:env_variables], index))
        end.inject(:merge)

        diff = tests - results.keys
        @logger.error("Tests #{diff.join(' ')} were not run") unless diff.empty?
        @logger.error("Queue #{queue.name} is not empty") unless queue.empty?

        info = Status.constants.map do |status|
          status = Status.const_get(status)
          [status, results.select { |_t, s| s == status }.keys]
        end.to_h
      end

      info.each do |s, tt|
        @logger.info("Total: #{s.to_s.upcase} tests (#{tt.count}): #{tt.join(' ')}") unless tt.empty?
      end

      @logger.info("\nTook #{total_mm} minutes #{total_ss} seconds")

      exit((diff + info[Status::FAILED] + info[Status::UNKNOWN]).empty? ? 0 : 1)
    end

    private

    def env_for_worker(env_variables, worker_number)
      env = env_variables.map do |k, v|
        case v
        when String, Numeric, TrueClass, FalseClass
          [k, v]
        when Array
          [k, v[worker_number]]
        when Hash
          value = v[worker_number.to_s]
          [k, value] unless value.nil?
        when NilClass
        else
          raise("Don't know how to set '#{v}'<#{v.class}> to the environment variable '#{k}'")
        end
      end.compact.to_h

      # Defaults, if absent in env. Shame 'merge' isn't something non-commutative like 'adopts/defaults'.
      env = { TEST: 1, TEST_PROCESS_NUMBER: worker_number }.merge(env)

      # Overwrite this if it exists in env.
      env.merge(PARALLEL_CUCUMBER_EXPORTS: env.keys.join(',')).map { |k, v| [k.to_s, v.to_s] }.to_h
    end
  end
end
