# frozen_string_literal: true

require "zip"
require "stringio"

module PreviewRendering
  class ThreeMfEmbeddedPreview
    PREFERRED_ENTRIES = [
      "Metadata/plate_1.png",
      "Metadata/top_1.png",
      "Metadata/pick_1.png",
      "Metadata/plate_no_light_1.png",
      "Metadata/plate_1_small.png"
    ].freeze

    def initialize(path)
      @path = path
    end

    def call
      return nil unless File.file?(@path)

      Zip::File.open(@path) do |archive|
        entry =
          preferred_entry(archive) ||
          largest_metadata_png(archive)

        return nil unless entry

        data = entry.get_input_stream.read

        return nil if data.blank?

        io = StringIO.new(data)
        io.binmode

        io
      end
    rescue Zip::Error, Errno::ENOENT => error
      Rails.logger.warn(
        {
          event: "three_mf_embedded_preview_failed",
          path: @path,
          error_class: error.class.name,
          error: error.message
        }.to_json
      )

      nil
    end

    private

    def preferred_entry(archive)
      PREFERRED_ENTRIES.each do |name|
        entry = archive.find_entry(name)

        return entry if entry
      end

      nil
    end

    def largest_metadata_png(archive)
      archive
        .entries
        .select do |entry|
          !entry.directory? &&
            entry.name.start_with?("Metadata/") &&
            entry.name.downcase.end_with?(".png")
        end
        .max_by(&:size)
    end
  end
end
