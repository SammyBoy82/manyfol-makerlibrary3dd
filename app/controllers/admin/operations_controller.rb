require "sidekiq/api"
require "fileutils"

module Admin
  class OperationsController < ApplicationController
    BACKUP_ROOT = Pathname.new("/archive/backups").freeze
    BACKUP_PACKAGES = BACKUP_ROOT.join("packages").freeze
    MANUAL_REQUEST = BACKUP_ROOT.join(".manual-backup-request").freeze
    SECONDARY_DESTINATION = BACKUP_ROOT.join(".secondary-destination").freeze
    ALLOWED_SECONDARY_ROOTS = %w[/srv /mnt /media /backup /var/backups].freeze

    before_action :authenticate_user!
    before_action :require_administrator!

    def index
      skip_policy_scope
      skip_authorization
      @snapshot = Admin::OperationsSnapshot.call
    end

    def control_center
      skip_policy_scope
      skip_authorization
      @snapshot = Admin::OperationsSnapshot.call
    end

    def backups
      skip_policy_scope
      skip_authorization

      FileUtils.mkdir_p(BACKUP_PACKAGES)
      @secondary_destination = SECONDARY_DESTINATION.exist? ? SECONDARY_DESTINATION.read.strip : ""
      @manual_request_pending = MANUAL_REQUEST.exist?
      @packages = Dir.glob(BACKUP_PACKAGES.join("*.tar.gz").to_s)
        .map { |path| Pathname.new(path) }
        .sort_by { |path| path.mtime }
        .reverse
        .first(100)
    rescue SystemCallError => error
      @secondary_destination = ""
      @manual_request_pending = false
      @packages = []
      flash.now[:alert] = "Backup storage unavailable: #{error.message}"
    end

    def request_backup
      skip_authorization

      FileUtils.mkdir_p(BACKUP_ROOT)
      MANUAL_REQUEST.write("#{Time.current.iso8601}\n")
      redirect_to admin_operations_backups_path,
        notice: "Manual backup requested. The host backup service will start it automatically."
    rescue SystemCallError => error
      redirect_to admin_operations_backups_path,
        alert: "Unable to request backup: #{error.message}"
    end

    def update_backup_settings
      skip_authorization

      destination = params[:secondary_destination].to_s.strip

      if destination.include?("\n") || destination.include?("\r")
        redirect_to admin_operations_backups_path,
          alert: "Secondary destination contains invalid characters."
        return
      end

      if destination.present? && !allowed_secondary_destination?(destination)
        redirect_to admin_operations_backups_path,
          alert: "Secondary destination must be an absolute path under /srv, /mnt, /media, /backup, or /var/backups."
        return
      end

      FileUtils.mkdir_p(BACKUP_ROOT)
      if destination.blank?
        FileUtils.rm_f(SECONDARY_DESTINATION)
      else
        SECONDARY_DESTINATION.write("#{destination}\n")
      end

      redirect_to admin_operations_backups_path,
        notice: destination.blank? ? "Secondary backup destination disabled." : "Secondary backup destination saved."
    rescue SystemCallError => error
      redirect_to admin_operations_backups_path,
        alert: "Unable to save backup settings: #{error.message}"
    end

    def download_backup
      skip_authorization

      filename = File.basename(params[:filename].to_s)
      unless filename.match?(/\Amakerlibrary3d-backup-\d{8}-\d{6}\.tar\.gz\z/)
        head :bad_request
        return
      end

      path = BACKUP_PACKAGES.join(filename)
      unless path.file?
        head :not_found
        return
      end

      send_file path,
        filename: filename,
        type: "application/gzip",
        disposition: "attachment"
    end

    def dead_jobs
      skip_policy_scope
      skip_authorization

      @jobs = Sidekiq::DeadSet.new.to_a.first(200)
    end

    def retry_dead_job
      skip_authorization

      job = Sidekiq::DeadSet.new.find_job(params[:jid])
      if job
        job.retry
        redirect_to admin_operations_dead_jobs_path, notice: "Dead job #{params[:jid]} queued for retry."
      else
        redirect_to admin_operations_dead_jobs_path, alert: "Dead job not found."
      end
    end

    def delete_dead_job
      skip_authorization

      job = Sidekiq::DeadSet.new.find_job(params[:jid])
      if job
        job.delete
        redirect_to admin_operations_dead_jobs_path, notice: "Dead job #{params[:jid]} deleted."
      else
        redirect_to admin_operations_dead_jobs_path, alert: "Dead job not found."
      end
    end

    def clear_dead_jobs
      skip_authorization

      count = Sidekiq::DeadSet.new.size
      Sidekiq::DeadSet.new.clear
      redirect_to admin_operations_dead_jobs_path, notice: "Cleared #{count} dead job(s)."
    end

    def problems
      skip_policy_scope
      skip_authorization

      @category = params[:category].to_s
      unless Problem.categories.key?(@category)
        redirect_to admin_operations_path, alert: "Unknown problem category."
        return
      end

      @problems = Problem.where(category: @category).order(created_at: :desc).limit(500)
    end

    private

    def allowed_secondary_destination?(destination)
      path = Pathname.new(destination).cleanpath.to_s
      ALLOWED_SECONDARY_ROOTS.any? { |root| path == root || path.start_with?("#{root}/") }
    end

    def require_administrator!
      return if current_user&.is_administrator?

      head :forbidden
    end
  end
end
