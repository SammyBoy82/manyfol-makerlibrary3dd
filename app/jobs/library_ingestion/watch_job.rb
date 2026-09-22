class LibraryIngestion::WatchJob < ApplicationJob
  queue_as :default
  unique :until_executed

  def perform
    control =
      LibraryIngestionControl.current

    if control.paused?
      Rails.logger.info(
        "library_ingestion_watch paused=true"
      )

      return
    end

    control.update!(
      last_run_at: Time.current,
      last_error: nil
    )

    discovered =
      LibraryIngestion::Scanner.new.scan

    queued = 0

    discovered.each do |ingest|
      next unless ingest.pending?

      LibraryIngestion::ProcessJob.perform_later(
        ingest.id
      )

      queued += 1
    end

    control.update!(
      last_success_at: Time.current,
      last_error: nil
    )

    Rails.logger.info(
      "library_ingestion_watch " \
      "discovered=#{discovered.count} " \
      "queued=#{queued}"
    )

  rescue => error
    begin
      LibraryIngestionControl.current.update!(
        last_run_at: Time.current,
        last_error:
          "#{error.class}: #{error.message}".truncate(4000)
      )
    rescue => control_error
      Rails.logger.error(
        "Unable to record watcher failure: " \
        "#{control_error.class}: #{control_error.message}"
      )
    end

    Rails.logger.error(
      "library_ingestion_watch_failed " \
      "#{error.class}: #{error.message}"
    )
  end
end
