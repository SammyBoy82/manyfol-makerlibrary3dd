module Admin
  class MediaMaintenanceController < ApplicationController
    before_action :authenticate_user!
    before_action :require_administrator!

    def index
      skip_policy_scope

      @health =
        Library.order(:name).map do |library|
          MediaMaintenance::LibraryHealth.call(library)
        end
    end

    def regenerate_missing
      skip_authorization

      library = Library.find(params[:library_id])

      queued = 0

      library.models.find_each do |model|
        model.model_files.each do |file|
          next unless file.is_3d_model?

          extension =
            file.extension.to_s.downcase

          next unless %w[stl obj 3mf].include?(extension)

          source_exists =
            begin
              file.exists_on_storage?
            rescue
              false
            end

          next unless source_exists

          render_path =
            file.path_within_library(
              derivative: :render
            )

          physical =
            begin
              library.has_file?(render_path)
            rescue
              false
            end

          next if file.has_render? && physical

          PreviewRendering::EnsureRenderJob.perform_later(file.id)

          queued += 1
        end
      end

      redirect_to(
        admin_media_maintenance_path,
        notice: "Queued #{queued} render job(s) for #{library.name}."
      )
    end

    private

    def require_administrator!
      return if current_user&.is_administrator?

      head :forbidden
    end
  end
end
