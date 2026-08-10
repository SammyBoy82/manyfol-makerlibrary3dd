module PreviewRendering
  class EnsureRenderJob < ApplicationJob
    queue_as :performance
    unique :until_executed

    discard_on ActiveRecord::RecordNotFound

    RENDERABLE_EXTENSIONS = %w[
      stl
      obj
      3mf
    ].freeze

    def perform(model_file_id)
      file = ModelFile.find(model_file_id)

      return unless file.is_3d_model?

      extension =
        file.extension.to_s.downcase

      unless RENDERABLE_EXTENSIONS.include?(extension)
        Rails.logger.info(
          "preview_render_skipped_unsupported " \
          "file_id=#{file.id} " \
          "extension=#{extension.inspect} " \
          "filename=#{file.filename.inspect}"
        )

        return
      end

      return unless file.exists_on_storage?

      render_path =
        file.path_within_library(
          derivative: :render
        )

      physical_render =
        begin
          file.model.library.has_file?(render_path)
        rescue
          false
        end

      # Healthy render already exists.
      return if file.has_render? && physical_render

      file.with_lock do
        file.reload

        render_path =
          file.path_within_library(
            derivative: :render
          )

        physical_render =
          begin
            file.model.library.has_file?(render_path)
          rescue
            false
          end

        # A stale render metadata record must not block regeneration.
        if file.has_render? && !physical_render
          data =
            Marshal.load(
              Marshal.dump(file.attachment_data)
            )

          derivatives =
            data["derivatives"] || {}

          derivatives.delete("render")

          if derivatives.empty?
            data.delete("derivatives")
          else
            data["derivatives"] =
              derivatives
          end

          file.attachment_data =
            data

          file.save!(
            validate: false,
            touch: false
          )

          file.reload
        end

        # Existing physical derivative but missing Shrine metadata.
        if !file.has_render? && physical_render
          Rails.logger.warn(
            "preview_render_orphan_detected " \
            "file_id=#{file.id} " \
            "filename=#{file.filename.inspect}"
          )

          return
        end

        return if file.has_render?

        Rails.logger.info(
          "preview_render_generation_started " \
          "file_id=#{file.id} " \
          "filename=#{file.filename.inspect}"
        )

        begin
          file.check_derivatives!
          file.reload

          if file.has_render?
            Rails.logger.info(
              "preview_render_generation_completed " \
              "file_id=#{file.id} " \
              "filename=#{file.filename.inspect}"
            )

            return
          end
        rescue StandardError => error
          Rails.logger.warn(
            "preview_render_generation_exception " \
            "file_id=#{file.id} " \
            "filename=#{file.filename.inspect} " \
            "error=#{error.class}: #{error.message}"
          )
        end

        if extension == "3mf"
          begin
            PreviewRendering::ThreeMfEmbeddedPreview.call(file)
            file.reload
          rescue StandardError => error
            Rails.logger.warn(
              "preview_3mf_fallback_failed " \
              "file_id=#{file.id} " \
              "error=#{error.class}: #{error.message}"
            )
          end
        end

        if file.has_render?
          Rails.logger.info(
            "preview_render_generation_completed " \
            "file_id=#{file.id} " \
            "filename=#{file.filename.inspect}"
          )
        else
          Rails.logger.warn(
            "preview_render_generation_failed " \
            "file_id=#{file.id} " \
            "filename=#{file.filename.inspect}"
          )
        end
      end
    end
  end
end
