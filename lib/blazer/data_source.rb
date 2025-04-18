module Blazer
  class DataSource
    extend Forwardable

    attr_reader :id, :settings

    def_delegators :adapter_instance, :schema, :tables, :preview_statement, :reconnect, :cost, :explain, :cancel, :supports_cohort_analysis?, :cohort_analysis_statement

    def initialize(id, settings)
      @id = id
      @settings = settings
    end

    def adapter
      settings["adapter"] || detect_adapter
    end

    def name
      settings["name"] || @id
    end

    def linked_columns
      settings["linked_columns"] || {}
    end

    def smart_columns
      settings["smart_columns"] || {}
    end

    def smart_variables
      settings["smart_variables"] || {}
    end

    def variable_defaults
      settings["variable_defaults"] || {}
    end

    def timeout
      settings["timeout"]
    end

    def cache
      @cache ||= begin
        if settings["cache"].is_a?(Hash)
          settings["cache"]
        elsif settings["cache"]
          {
            "mode" => "all",
            "expires_in" => settings["cache"]
          }
        else
          {
            "mode" => "off"
          }
        end
      end
    end

    def cache_mode
      cache["mode"]
    end

    def cache_expires_in
      (cache["expires_in"] || 60).to_f
    end

    def cache_slow_threshold
      (cache["slow_threshold"] || 15).to_f
    end

    def local_time_suffix
      @local_time_suffix ||= Array(settings["local_time_suffix"])
    end

    def result_cache
      @result_cache ||= Blazer::ResultCache.new(self)
    end

    def run_results(run_id)
      result_cache.read_run(run_id)
    end

    def delete_results(run_id)
      result_cache.delete_run(run_id)
    end

    def sub_variables(statement, vars)
      statement = statement.dup
      vars.each do |var, value|
        # use block form to disable back-references
        statement.gsub!("{#{var}}") { quote(value) }
      end
      statement
    end

    def run_statement(statement, options = {})
      statement = Statement.new(statement, self) if statement.is_a?(String)
      statement.bind unless statement.bind_statement

      result = nil
      if cache_mode != "off"
        if options[:refresh_cache]
          clear_cache(statement) # for checks
        else
          result = result_cache.read_statement(statement)
        end
      end

      unless result
        comment = "blazer".dup
        if options[:user].respond_to?(:id)
          comment << ",user_id:#{options[:user].id}"
        end
        if options[:user].respond_to?(Blazer.user_name)
          # only include letters, numbers, and spaces to prevent injection
          comment << ",user_name:#{options[:user].send(Blazer.user_name).to_s.gsub(/[^a-zA-Z0-9 ]/, "")}"
        end
        if options[:query].respond_to?(:id)
          comment << ",query_id:#{options[:query].id}"
        end
        if options[:check]
          comment << ",check_id:#{options[:check].id},check_emails:#{options[:check].emails}"
        end
        if options[:run_id]
          comment << ",run_id:#{options[:run_id]}"
        end
        result = run_statement_helper(statement, comment, options)
      end

      if options[:async] && options[:run_id]
        run_id = options[:run_id]
        begin
          result_cache.write_run(run_id, result)
        rescue
          result = Blazer::Result.new(self, [], [], "Error storing the results of this query :(", nil, false)
          result_cache.write_run(run_id, result)
        end
      end

      result
    end

    def clear_cache(statement)
      result_cache.delete_statement(statement)
    end

    def quote(value)
      if quoting == :backslash_escape || quoting == :single_quote_escape
        # only need to support types generated by process_vars
        if value.is_a?(Integer) || value.is_a?(Float)
          value.to_s
        elsif value.nil?
          "NULL"
        else
          value = value.to_formatted_s(:db) if value.is_a?(ActiveSupport::TimeWithZone)

          if quoting == :backslash_escape
            "'#{value.gsub("\\") { "\\\\" }.gsub("'") { "\\'" }}'"
          else
            "'#{value.gsub("'", "''")}'"
          end
        end
      elsif quoting.respond_to?(:call)
        quoting.call(value)
      elsif quoting.nil?
        raise Blazer::Error, "Quoting not specified"
      else
        raise Blazer::Error, "Unknown quoting"
      end
    end

    def bind_params(statement, variables)
      if parameter_binding == :positional
        locations = []
        variables.each do |k, v|
          i = 0
          while (idx = statement.index("{#{k}}", i))
            locations << [v, idx]
            i = idx + 1
          end
        end
        variables.each do |k, v|
          statement = statement.gsub("{#{k}}", "?")
        end
        [statement, locations.sort_by(&:last).map(&:first)]
      elsif parameter_binding == :numeric
        variables.each_with_index do |(k, v), i|
          # add trailing space if followed by digit
          # try to keep minimal to avoid fixing invalid queries like SELECT{var}
          statement = statement.gsub(/#{Regexp.escape("{#{k}}")}(\d)/, "$#{i + 1} \\1").gsub("{#{k}}", "$#{i + 1}")
        end
        [statement, variables.values]
      elsif parameter_binding.respond_to?(:call)
        parameter_binding.call(statement, variables)
      elsif parameter_binding.nil?
        [sub_variables(statement, variables), []]
      else
        raise Blazer::Error, "Unknown bind parameters"
      end
    end

    protected

    def adapter_instance
      @adapter_instance ||= begin
        # TODO add required settings to adapters
        unless settings["url"] || Rails.env.development? || ["bigquery", "athena", "snowflake", "salesforce"].include?(settings["adapter"])
          raise Blazer::Error, "Empty url for data source: #{id}"
        end

        unless Blazer.adapters[adapter]
          raise Blazer::Error, "Unknown adapter"
        end

        Blazer.adapters[adapter].new(self)
      end
    end

    def quoting
      @quoting ||= adapter_instance.quoting
    end

    def parameter_binding
      @parameter_binding ||= adapter_instance.parameter_binding
    end

    def run_statement_helper(statement, comment, options)
      start_time = Blazer.monotonic_time
      columns, rows, error =
        if adapter_instance.parameter_binding
          adapter_instance.run_statement(statement.bind_statement, comment, statement.bind_values)
        else
          adapter_instance.run_statement(statement.bind_statement, comment)
        end
      duration = Blazer.monotonic_time - start_time

      cache = !error && (cache_mode == "all" || (cache_mode == "slow" && duration >= cache_slow_threshold))

      result = Blazer::Result.new(self, columns, rows, error, cache ? Time.now : nil, false)

      if cache && adapter_instance.cachable?(statement.bind_statement)
        begin
          result_cache.write_statement(statement, result, expires_in: cache_expires_in.to_f * 60)
          # set just_cached after caching
          result.just_cached = true
        rescue
          # do nothing
        end
      end

      result.cached_at = nil
      result
    end

    # TODO check for adapter with same name, default to sql
    def detect_adapter
      scheme = settings["url"].to_s.split("://").first
      case scheme
      when "presto", "trino", "cassandra", "ignite"
        scheme
      else
        "sql"
      end
    end
  end
end
