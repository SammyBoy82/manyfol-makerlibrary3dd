class Admin::LibraryIngestsController < ApplicationController
  before_action :require_administrator!

  skip_after_action :verify_authorized
  skip_after_action :verify_policy_scoped

  def index
    @control =
      LibraryIngestionControl.current

    @summary = {
      pending: LibraryIngest.where(status: "pending").count,
      processing: LibraryIngest.where(status: "processing").count,
      completed: LibraryIngest.where(status: "completed").count,
      failed: LibraryIngest.where(status: "failed").count,
      duplicates:
        LibraryIngest.where(
          duplicate_status: [
            "duplicate_same_library",
            "duplicate_other_library"
          ]
        ).count
    }

    @libraries =
      Library.order(:name)

    @ingests =
      LibraryIngest
        .includes(
          :library,
          :model,
          duplicate_model_file: :model
        )
        .recent
        .limit(100)
  end

  def scan
    discovered =
      LibraryIngestion::Scanner.new.scan

    discovered.each do |ingest|
      next unless ingest.pending?

      LibraryIngestion::ProcessJob.perform_later(
        ingest.id
      )
    end

    redirect_to admin_library_ingests_path,
      notice: "Import scan completed. #{discovered.count} item(s) discovered."
  end

  def override_duplicate
    ingest =
      LibraryIngest.find(params[:id])

    ingest.update!(
      duplicate_override: true,
      status: "pending",
      processing_status: "waiting",
      error_message: nil,
      processing_error: nil,
      started_at: nil,
      completed_at: nil
    )

    LibraryIngestion::ProcessJob.perform_later(
      ingest.id
    )

    redirect_to admin_library_ingests_path,
      notice: "Duplicate override accepted. Ingestion queued."
  end

  def pause
    LibraryIngestionControl.current.update!(
      paused: true
    )

    redirect_to admin_library_ingests_path,
      notice: "Automatic ingestion paused."
  end

  def resume
    LibraryIngestionControl.current.update!(
      paused: false,
      last_error: nil
    )

    redirect_to admin_library_ingests_path,
      notice: "Automatic ingestion resumed."
  end

  def run_now
    LibraryIngestion::WatchJob.perform_later

    redirect_to admin_library_ingests_path,
      notice: "Ingestion watcher queued."
  end

  def toggle_library
    library =
      Library.find(params[:id])

    library.update!(
      ingestion_enabled:
        !library.ingestion_enabled?
    )

    redirect_to admin_library_ingests_path,
      notice:
        "#{library.name} ingestion "         "#{library.ingestion_enabled? ? "enabled" : "disabled"}."
  end

  def retry
    ingest =
      LibraryIngest.find(params[:id])

    if ingest.failed?
      ingest.update!(
        status: "pending",
        error_message: nil,
        started_at: nil,
        completed_at: nil
      )

      LibraryIngestion::ProcessJob.perform_later(
        ingest.id
      )
    end

    redirect_to admin_library_ingests_path
  end

  private

  def require_administrator!
    raise Pundit::NotAuthorizedError unless current_user&.is_administrator?
  end
end
