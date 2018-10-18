require 'open3'
require 'json'

module Salus
  class NpmAuditWrapper
    # Structure to hold the relevant information about a given adivsory
    Advisory = Struct.new(:id, :module, :title, :severity, :url, :prod?, :excepted?)

    # Some common, easily-abbreviated terms to shorten advisory titles
    TITLE_SUBSTITUTIONS = {
      'Regular Expression'    => 'Regex',
      'Denial of Service'     => 'DoS',
      'Remote Code Execution' => 'RCE'
    }.freeze

    # Cap title and module name length to avoid the table getting too wide
    MAX_MODULE_LENGTH = 16
    MAX_TITLE_LENGTH = 16

    # Headings for the tabulated report
    TABLE_HEADINGS = ['ID', 'Module', 'Title', 'Sev.', 'URL', 'Prod', 'Ex.'].freeze

    # Terminal colors
    COLORS = {
      red: 31,
      yellow: 33,
      green: 32
    }.freeze

    def initialize(stream:, exceptions:, path:, colors: true)
      @stream = stream
      @exceptions = exceptions.map(&:to_s).sort_by(&:to_i)
      @path = path
      @colors = colors
    end

    def run!
      Dir.chdir(@path) do
        ensure_package_lock! do
          raw = run_command!('npm audit --json')
          raw_advisories = JSON.parse(raw, symbolize_names: true).fetch(:advisories).values

          advisories = raw_advisories.map do |radv|
            # If the advisory exists in a prod dependency, there'll be some finding
            # where dev is false
            prod = radv.fetch(:findings).any? { |finding| !finding.fetch(:dev) }

            id = radv.fetch(:id).to_s
            excepted = @exceptions.include?(id)

            Advisory.new(
              id,
              radv.fetch(:module_name),
              radv.fetch(:title),
              radv.fetch(:severity),
              radv.fetch(:url),
              prod,
              excepted
            )
          end

          # Sort advisories with un-excepted prod vulnerabilities first,
          # and in ascending order of ID otherwise
          advisories.sort_by! do |advisory|
            unexcepted_and_prod = !advisory.excepted? && advisory.prod?
            [(unexcepted_and_prod ? 0 : 1), advisory.id.to_i]
          end

          advisories_by_id = advisories.map(&:id).zip(advisories).to_h

          # The build fails iff there exist un-expect advisories against prod deps
          failing_advisory_ids = advisories.select { |adv| !adv.excepted? && adv.prod? }.map(&:id)

          # For informational purposes, we record any exceptions that don't refer
          # to an actual advisory
          extraneous_exceptions = @exceptions.reject { |id| advisories_by_id.key?(id) }

          # Also, we record any exceptions that apply only to dev dependencies
          extraneous_dev_exceptions = @exceptions.select do |id|
            adv = advisories_by_id[id]
            !adv.nil? && !adv.prod?
          end

          if advisories.any?
            log(tabulate_advisories(advisories))
          else
            log(colorize('There are no advisories against your dependencies. Hooray!', :green))
          end

          if failing_advisory_ids.any?
            s = failing_advisory_ids.join(', ')
            log("Audit failed pending the following advisory(s): #{s}.")
            log('To fix the build, please resolve the previous advisory(s), or add exceptions.')
          end

          if extraneous_exceptions.any? || extraneous_dev_exceptions.any?
            if extraneous_exceptions.any?
              log(
                'The following exception(s) do not match any advisory against the directory: ' \
                "#{extraneous_exceptions.join(', ')}."
              )
            end

            if extraneous_dev_exceptions.any?
              log(
                'The following exceptions apply only to development dependencies: ' \
                "#{extraneous_dev_exceptions.join(', ')}."
              )
            end

            log('These exceptions can safely be removed.')
          end

          failing_advisory_ids.empty?
        end
      end
    end

    private

    def log(string)
      @stream.puts(string)
    end

    def ensure_package_lock!
      created_package_lock = false

      if !File.exist?('package-lock.json')
        log('Creating a temporary package-lock.json...')
        run_command!('npm install --package-lock-only', raise_on_failure: true)
        created_package_lock = true
      end

      yield
    ensure
      if created_package_lock
        File.delete("package-lock.json")
        log('Removed temporary package-lock.json')
      end
    end

    def run_command!(command, raise_on_failure: false)
      stdout = nil
      status = nil

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      Open3.popen3(command) do |_, out, _, thread|
        status = thread.value
        stdout = out.read
      end

      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).round(2)

      log("Ran `#{command}`; finished in #{duration}s with exit code #{status.exitstatus}")

      if raise_on_failure && !status.success?
        raise "`#{command}` failed with exit code #{status.exitstatus}"
      end

      stdout
    end

    def abbreviate_title(title)
      TITLE_SUBSTITUTIONS.each { |from, to| title = title.gsub(from, to) }
      title = title[0...(MAX_TITLE_LENGTH - 1)] + '~' if title.length > MAX_TITLE_LENGTH
      title
    end

    def abbreviate_module(mod)
      mod = mod[0...(MAX_MODULE_LENGTH - 1)] + '~' if mod.length > MAX_MODULE_LENGTH
      mod
    end

    def abbreviate_severity(severity)
      case severity
      when 'critical' then 'crit'
      when 'moderate' then 'mod'
      else severity
      end
    end

    def tabulate_advisories(advisories)
      table = advisories.map do |advisory|
        [
          advisory.id,
          abbreviate_module(advisory.module),
          abbreviate_title(advisory.title),
          abbreviate_severity(advisory.severity),
          advisory.url.gsub('https://', ''),
          (advisory.prod? ? 'y' : 'n'),
          (advisory.excepted? ? 'y' : 'n')
        ]
      end

      table = [TABLE_HEADINGS] + table

      colors = [nil] + advisories.map do |adv|
        if adv.prod? && !adv.excepted?
          :red
        elsif adv.prod? && adv.excepted?
          :yellow
        end
      end

      # Figure out the longest element of any given table column
      max_lengths = (0...TABLE_HEADINGS.length).map do |column_index|
        table.map { |row| row[column_index].length }.max
      end

      # Pad every table cell such that:
      # - every cell gets at least one leading and trailing space
      # - every cell is of equal size to the largest cell in its column

      rows = table.each_with_index.map do |row, row_index|
        cells = row.each_with_index.map do |datum, column_index|
          right_padding = 1 + max_lengths[column_index] - datum.length
          ' ' + datum + (' ' * right_padding)
        end

        colorize(cells.join('|'), colors[row_index])
      end

      width = rows[0].length

      # Add some horizontal lines
      rows.insert(0, '=' * width)
      rows.insert(2, '-' * width)
      rows.push('=' * width)

      rows.join("\n")
    end

    def colorize(string, code)
      return string if !@colors || code.nil?
      "\e[#{COLORS.fetch(code)}m#{string}\e[0m"
    end
  end
end