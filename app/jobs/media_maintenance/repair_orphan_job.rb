module MediaMaintenance
  class RepairOrphanJob < ApplicationJob
    queue_as :performance

    def perform(model_file_id)
      file = ModelFile.find_by(id: model_file_id)
      return unless file&.is_3d_model?
      return unless %w[stl obj 3mf].include?(file.extension.to_s.downcase)
      return unless file.exists_on_storage?

      library = file.model.library
      render_path = file.path_within_library(derivative: :render)
      physical_render = library.has_file?(render_path)

      return unless !file.has_render? && physical_render

      file.check_derivatives!
    rescue => e
      Rails.logger.error(
        {
          event: "media_maintenance_repair_orphan_failed",
          model_file_id: model_file_id,
          error: e.class.name,
          message: e.message
        }.to_json
      )
      raise
    end
  end
end
