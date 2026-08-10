# frozen_string_literal: true

module PreviewRendering
  class EnsureRenderJob < ApplicationJob
    # 3D rendering is CPU-heavy.
    # Keep it away from the normal/default application queue.
    queue_as :performance

    # CRITICAL:
    # Never allow several jobs for the same ModelFile to render
    # the same derivative concurrently.
    unique :until_executed

    discard_on ActiveRecord::RecordNotFound

    def perform(model_file_id)
      file = ModelFile.find(model_file_id)

      return unless file.is_3d_model?

      file.reload
      return if healthy_render?(file)

      Rails.logger.info(
        "preview_render_generation_started " \
        "file_id=#{file.id} filename=#{file.filename.inspect}"
      )

      file.with_lock do
        file.reload

        return if healthy_render?(file)

        file.check_derivatives!
        file.reload

        if healthy_render?(file)
          Rails.logger.info(
            "preview_render_generation_completed " \
            "file_id=#{file.id} filename=#{file.filename.inspect}"
          )
          return
        end

        Rails.logger.warn(
          "preview_render_generation_failed " \
          "file_id=#{file.id} filename=#{file.filename.inspect}"
        )
      end
    rescue StandardError => error
      Rails.logger.error(
        "preview_render_generation_exception " \
        "file_id=#{model_file_id} " \
        "error=#{error.class}: #{error.message}"
      )
    end

    private

    def healthy_render?(file)
      return false unless file.has_render?

      expected =
        file.path_within_library(
          derivative: :render
        )

      file.model.library.has_file?(expected)
    rescue StandardError
      false
    end
  end
end
