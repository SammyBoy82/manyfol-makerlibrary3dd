module Admin
  class IntegrityPreview
    SUPPORTED_CATEGORIES = %w[missing duplicate nesting].freeze
    LIMIT = 250

    Result = Struct.new(:category, :generated_at, :total, :rows, :summary, keyword_init: true)

    def self.call(category)
      new(category).call
    end

    def initialize(category)
      @category = category.to_s
      raise ArgumentError, "Unsupported integrity preview category: #{@category}" unless SUPPORTED_CATEGORIES.include?(@category)
    end

    def call
      scope = Problem.where(category: @category).order(created_at: :desc)
      rows = scope.limit(LIMIT).map { |problem| build_row(problem) }

      Result.new(
        category: @category,
        generated_at: Time.current,
        total: scope.count,
        rows: rows,
        summary: summarize(rows)
      )
    end

    private

    def build_row(problem)
      case @category
      when "missing"
        missing_row(problem)
      when "duplicate"
        duplicate_row(problem)
      when "nesting"
        nesting_row(problem)
      end
    rescue => error
      base_row(problem).merge(
        state: :error,
        recommendation: "Manual review required",
        impact: "No automatic action proposed",
        error: "#{error.class}: #{error.message}"
      )
    end

    def base_row(problem)
      object = problem.problematic
      {
        problem_id: problem.id,
        problematic_type: problem.problematic_type,
        problematic_id: problem.problematic_id,
        object: object,
        label: label_for(object),
        library: library_for(object),
        path: path_for(object),
        detected_at: problem.created_at
      }
    end

    def missing_row(problem)
      row = base_row(problem)
      object = problem.problematic

      unless object
        return row.merge(
          state: :orphan_problem,
          recommendation: "Clear orphan problem record",
          impact: "Problem record only; underlying object is already absent",
          storage_exists: nil
        )
      end

      if object.respond_to?(:exists_on_storage?)
        exists = object.exists_on_storage?
        return row.merge(
          storage_exists: exists,
          state: exists ? :stale_problem : :confirmed_missing,
          recommendation: exists ? "Clear stale missing flag after rescan" : "Review database record for removal",
          impact: exists ? "No file deletion; refresh integrity state only" : "Would remove the database reference only after explicit approval"
        )
      end

      row.merge(
        storage_exists: nil,
        state: :needs_review,
        recommendation: "Manual storage verification",
        impact: "No automatic action proposed"
      )
    end

    def duplicate_row(problem)
      row = base_row(problem)
      file = problem.problematic

      unless file.is_a?(ModelFile)
        return row.merge(
          state: :needs_review,
          recommendation: "Manual duplicate review",
          impact: "No automatic action proposed",
          duplicate_count: 0,
          duplicate_candidates: []
        )
      end

      candidates = file.duplicates.includes(model: :library).limit(20).map do |candidate|
        {
          id: candidate.id,
          label: candidate.name_and_filename,
          library: candidate.model&.library&.name,
          path: candidate.path_within_library,
          size: candidate.size,
          same_model: candidate.model_id == file.model_id
        }
      end

      row.merge(
        state: candidates.any? ? :duplicate_set : :stale_problem,
        recommendation: candidates.any? ? "Compare locations and choose canonical copy" : "Clear stale duplicate flag after rescan",
        impact: candidates.any? ? "No file will be removed until a canonical copy is explicitly selected" : "No file deletion; refresh integrity state only",
        digest: file.digest,
        size: file.size,
        duplicate_count: candidates.size,
        duplicate_candidates: candidates
      )
    end

    def nesting_row(problem)
      row = base_row(problem)
      model = problem.problematic

      unless model.is_a?(Model)
        return row.merge(
          state: :needs_review,
          recommendation: "Manual nesting review",
          impact: "No automatic action proposed",
          nested_models: []
        )
      end

      nested = model.library.models.where.not(id: model.id).select { |candidate| model.contains?(candidate) }
      parents = model.parents

      row.merge(
        state: nested.any? || parents.any? ? :structural_conflict : :stale_problem,
        recommendation: nested.any? ? "Preview merge of nested models into this parent" : parents.any? ? "Review merge into parent model" : "Clear stale nesting flag after rescan",
        impact: "Preview only. No paths, files, metadata, or models are changed.",
        model_path: model.path,
        parent_models: parents.map { |parent| {id: parent.id, name: parent.name, path: parent.path} },
        nested_models: nested.first(30).map { |child| {id: child.id, name: child.name, path: child.path, files: child.model_files.count} }
      )
    end

    def summarize(rows)
      rows.group_by { |row| row[:state] }.transform_values(&:count)
    end

    def label_for(object)
      return "Deleted object" unless object
      return object.name_and_filename if object.respond_to?(:name_and_filename)
      return object.name if object.respond_to?(:name)
      "#{object.class.name} ##{object.id}"
    end

    def library_for(object)
      return nil unless object
      return object.library.name if object.respond_to?(:library) && object.library
      return object.model.library.name if object.respond_to?(:model) && object.model&.library
      nil
    end

    def path_for(object)
      return nil unless object
      return object.path_within_library if object.respond_to?(:path_within_library)
      return object.path if object.respond_to?(:path)
      nil
    end
  end
end
