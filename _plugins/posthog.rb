# frozen_string_literal: true

require "dotenv/load"

module PostHogLogCapture
  def self.configure(project_token, host)
    require "opentelemetry/sdk"
    require "opentelemetry/exporter/otlp"

    exporter = OpenTelemetry::Exporter::OTLP::Logs::LogsExporter.new(
      endpoint: "#{host.sub(%r{/\z}, "")}/i/v1/logs",
      headers: { "Authorization" => "Bearer #{project_token}" }
    )
    provider = OpenTelemetry::SDK::Logs::LoggerProvider.new
    provider.add_log_record_processor(
      OpenTelemetry::SDK::Logs::Export::BatchLogRecordProcessor.new(exporter)
    )

    [provider, provider.logger(name: "posthog.jekyll")]
  end

  def self.emit(logger, body, attributes = {})
    logger.emit(severity_text: "INFO", body: body, attributes: attributes)
  rescue StandardError => error
    Jekyll.logger.debug("PostHog", "Log capture failed: #{error.class}")
  end
end

Jekyll::Hooks.register :site, :after_init do |site|
  project_token = ENV["POSTHOG_PROJECT_TOKEN"]
  host = ENV["POSTHOG_HOST"]

  if project_token&.strip&.length&.positive? && host&.strip&.length&.positive?
    site.config["posthog"] = {
      "project_token" => project_token,
      "host" => host
    }

    begin
      log_provider, log = PostHogLogCapture.configure(project_token, host)
      site.config["posthog_log_capture"] = { "provider" => log_provider, "logger" => log }
      PostHogLogCapture.emit(
        log,
        "jekyll_site_initialized",
        { "jekyll_environment" => ENV.fetch("JEKYLL_ENV", "development") }
      )

      at_exit do
        begin
          log_provider.force_flush(timeout: 3)
        rescue StandardError => error
          Jekyll.logger.debug("PostHog", "Log export flush failed: #{error.class}")
        ensure
          begin
            log_provider.shutdown(timeout: 3)
          rescue StandardError => error
            Jekyll.logger.debug("PostHog", "Log exporter shutdown failed: #{error.class}")
          end
        end
      end
    rescue LoadError, StandardError => error
      Jekyll.logger.debug("PostHog", "Log capture setup failed: #{error.class}")
    end
  elsif ENV["JEKYLL_ENV"] != "production"
    missing_variable = project_token.to_s.strip.empty? ? "POSTHOG_PROJECT_TOKEN" : "POSTHOG_HOST"

    Jekyll.logger.warn(
      "PostHog",
      "#{missing_variable} variable required by PostHog is missing or un-configured, this causes events to be silently missed. This error stops appearing once #{missing_variable} is configured"
    )
  end
end

Jekyll::Hooks.register :site, :post_write do |site|
  log = site.config.dig("posthog_log_capture", "logger")
  PostHogLogCapture.emit(log, "jekyll_site_written") if log
end
