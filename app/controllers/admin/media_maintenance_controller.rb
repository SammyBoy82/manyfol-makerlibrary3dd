require "sidekiq/api"

module Admin
  class MediaMaintenanceController < ApplicationController
    before_action :authenticate_user!
    before_action :require_administrator!

    RENDERABLE_EXTENSIONS = %w[stl obj 3mf].freeze

    def index
      skip_policy_scope

      @health =
        Library.order(:name).map do |library|
          MediaMaintenance::LibraryHealth.call(library)
        end

      @queue_status = {
        default: Sidekiq::Queue.new("default").size,
        performance: Sidekiq::Queue.new("performance").size,
        scan: Sidekiq::Queue.new("scan").size,
        critical: Sidekiq::Queue.new("critical").size,
        retries: Sidekiq::RetrySet.new.size,
        scheduled: Sidekiq::ScheduledSet.new.size,
        dead: Sidekiq::DeadSet.new.size,
        processes: Sidekiq::ProcessSet.new.size
      }
    end

    def missing_sources
      skip_policy_scope
      skip_authorization

      @library = Library.find(params[:library_id])
      @rows = []

      @library.models.find_each do |model|
        model.model_files.each do |file|
          next unless file.is_3d_model?
          next unless RENDERABLE_EXTENSIONS.include?(file.extension.to_s.downcase)

          source_exists =
            begin
              file.exists_on_storage?
            rescue
              false
            end

          next if source_exists

          @rows << {
            id: file.id,
            model_id: model.id,
            model_name: model.name,
            filename: file.filename,
            extension: file.extension.to_s.downcase,
            storage_key: file.attachment.storage_key.to_s,
            attachment_id: file.attachment.id,
            library_relative_path: file.attachment.id
          }
        end
      end

      @rows.sort_by! do |row|
        [
          row[:model_name].to_s.downcase,
          row[:filename].to_s.downcase
        ]
      end
    end

    def rescan
      skip_authorization

      library = Library.find(params[:library_id])
      library.detect_filesystem_changes_later

      redirect_to(
        admin_media_maintenance_path,
        notice: "Queued filesystem rescan for #{library.name}."
      )
    end

    def repair_stale
      skip_authorization

      library = Library.find(params[:library_id])
      queued = 0

      each_renderable_file(library) do |file|
        next unless source_exists?(file)

        physical = physical_render?(library, file)
        next unless file.has_render? && !physical

        PreviewRendering::EnsureRenderJob.perform_later(file.id)
        queued += 1
      end

      redirect_to(
        admin_media_maintenance_path,
        notice: "Queued #{queued} stale render repair job(s) for #{library.name}."
      )
    end

    def repair_orphans
      skip_authorization

      library = Library.find(params[:library_id])
      queued = 0

      each_renderable_file(library) do |file|
        next unless source_exists?(file)

        physical = physical_render?(library, file)
        next unless !file.has_render? && physical

        MediaMaintenance::RepairOrphanJob.perform_later(file.id)
        queued += 1
      end

      redirect_to(
        admin_media_maintenance_path,
        notice: "Queued #{queued} orphan repair job(s) for #{library.name}."
      )
    end

    def regenerate_missing
      skip_authorization

      library = Library.find(params[:library_id])
      queued = 0

      each_renderable_file(library) do |file|
        next unless source_exists?(file)

        physical = physical_render?(library, file)
        next if file.has_render? || physical

        PreviewRendering::EnsureRenderJob.perform_later(file.id)
        queued += 1
      end

      redirect_to(
        admin_media_maintenance_path,
        notice: "Queued #{queued} missing render job(s) for #{library.name}."
      )
    end

    private

    def each_renderable_file(library)
      library.models.find_each do |model|
        model.model_files.each do |file|
          next unless file.is_3d_model?
          next unless RENDERABLE_EXTENSIONS.include?(file.extension.to_s.downcase)

          yield file
        end
      end
    end

    def source_exists?(file)
      file.exists_on_storage?
    rescue
      false
    end

    def physical_render?(library, file)
      render_path = file.path_within_library(derivative: :render)
      library.has_file?(render_path)
    rescue
      false
    end

    def require_administrator!
      return if current_user&.is_administrator?

      head :forbidden
    end
  end
end
