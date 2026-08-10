module MediaMaintenance
  class LibraryHealth
    RENDERABLE_EXTENSIONS = %w[
      stl
      obj
      3mf
    ].freeze

    Result = Struct.new(
      :library,
      :total_3d,
      :healthy,
      :stale_metadata,
      :orphan_render,
      :missing_renderable,
      :missing_source,
      :unsupported,
      keyword_init: true
    )

    def self.call(library)
      new(library).call
    end

    def initialize(library)
      @library = library
    end

    def call
      total_3d = 0
      healthy = 0
      stale_metadata = 0
      orphan_render = 0
      missing_renderable = 0
      missing_source = 0
      unsupported = Hash.new(0)

      library.models.find_each do |model|
        model.model_files.each do |file|
          next unless file.is_3d_model?

          total_3d += 1

          extension =
            file.extension.to_s.downcase

          source_exists =
            begin
              file.exists_on_storage?
            rescue
              false
            end

          render_path =
            file.path_within_library(
              derivative: :render
            )

          physical_render =
            begin
              library.has_file?(render_path)
            rescue
              false
            end

          unless RENDERABLE_EXTENSIONS.include?(extension)
            unsupported[extension] += 1
            next
          end

          unless source_exists
            missing_source += 1
            next
          end

          if file.has_render? && physical_render
            healthy += 1

          elsif file.has_render? && !physical_render
            stale_metadata += 1

          elsif !file.has_render? && physical_render
            orphan_render += 1

          else
            missing_renderable += 1
          end
        end
      end

      Result.new(
        library: library,
        total_3d: total_3d,
        healthy: healthy,
        stale_metadata: stale_metadata,
        orphan_render: orphan_render,
        missing_renderable: missing_renderable,
        missing_source: missing_source,
        unsupported: unsupported
      )
    end

    private

    attr_reader :library
  end
end
