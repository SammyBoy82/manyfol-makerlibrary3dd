module Admin
  class FileStorageAnomalies
    ExtensionRow = Struct.new(
      :extension,
      :files,
      :bytes,
      keyword_init: true
    )

    Result = Struct.new(
      :zero_byte_files,
      :missing_size_files,
      :rare_extensions,
      :largest_files,
      :largest_models,
      keyword_init: true
    )

    def self.call
      new.call
    end

    def call
      Result.new(
        zero_byte_files: zero_byte_files,
        missing_size_files: missing_size_files,
        rare_extensions: rare_extensions,
        largest_files: largest_files,
        largest_models: largest_models
      )
    end

    private

    def zero_byte_files
      ModelFile
        .includes(model: :library)
        .where(size: 0)
        .order(:filename)
        .limit(250)
        .to_a
    end

    def missing_size_files
      ModelFile
        .includes(model: :library)
        .where(size: nil)
        .order(:filename)
        .limit(250)
        .to_a
    end

    def rare_extensions
      stats = Hash.new { |hash, key| hash[key] = {files: 0, bytes: 0} }

      ModelFile
        .where.not(filename: nil)
        .pluck(:filename, :size)
        .each do |filename, size|

        extension =
          File.extname(filename.to_s)
            .delete(".")
            .downcase
            .presence || "(none)"

        stats[extension][:files] += 1
        stats[extension][:bytes] += size.to_i
      end

      stats
        .filter_map do |extension, values|
          next if values[:files] > 3

          ExtensionRow.new(
            extension: extension,
            files: values[:files],
            bytes: values[:bytes]
          )
        end
        .sort_by { |row| [row.files, row.extension] }
    end

    def largest_files
      ModelFile
        .includes(model: :library)
        .where.not(size: nil)
        .order(size: :desc)
        .limit(50)
        .to_a
    end

    def largest_models
      rows =
        Model
          .joins(:model_files)
          .group("models.id")
          .order(Arel.sql("COALESCE(SUM(model_files.size), 0) DESC"))
          .limit(50)
          .pluck(
            "models.id",
            Arel.sql("COUNT(model_files.id)"),
            Arel.sql("COALESCE(SUM(model_files.size), 0)")
          )

      models =
        Model
          .includes(:library)
          .where(id: rows.map(&:first))
          .index_by(&:id)

      rows.filter_map do |model_id, files, bytes|
        model = models[model_id]
        next unless model

        {
          model: model,
          library: model.library,
          files: files.to_i,
          bytes: bytes.to_i
        }
      end
    end
  end
end
