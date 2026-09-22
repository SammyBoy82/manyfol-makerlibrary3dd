module Admin
  class NestingAnalyzer
    LIMIT = 100

    Result = Struct.new(:generated_at, :problem_count, :groups, keyword_init: true)

    def self.call
      new.call
    end

    def call
      problems = Problem.where(category: "nesting", problematic_type: "Model").includes(problematic: :library).limit(LIMIT)

      groups = problems.filter_map do |problem|
        model = problem.problematic
        next unless model.is_a?(Model)

        build_group(problem, model)
      end

      Result.new(
        generated_at: Time.current,
        problem_count: Problem.where(category: "nesting").count,
        groups: groups
      )
    end

    private

    def build_group(problem, model)
      parents = model.parents
      children = model.library.models.where.not(id: model.id).select { |candidate| model.contains?(candidate) }

      role = if children.any?
        :parent_with_children
      elsif parents.any?
        :child_inside_parent
      else
        :stale
      end

      {
        problem_id: problem.id,
        model_id: model.id,
        model_name: model.name,
        library: model.library&.name,
        path: model.path,
        role: role,
        file_count: model.model_files.count,
        three_d_count: model.model_files.count(&:is_3d_model?),
        image_count: model.model_files.count(&:is_image?),
        parent_models: parents.map { |parent| model_summary(parent) },
        child_models: children.first(30).map { |child| model_summary(child) },
        explanation: explanation(role, parents.size, children.size)
      }
    end

    def model_summary(model)
      {
        id: model.id,
        name: model.name,
        path: model.path,
        file_count: model.model_files.count,
        three_d_count: model.model_files.count(&:is_3d_model?),
        image_count: model.model_files.count(&:is_image?),
        preview_file_id: model.preview_file_id,
        entrypoint_id: model.entrypoint_id
      }
    end

    def explanation(role, parent_count, child_count)
      case role
      when :parent_with_children
        "This model folder contains #{child_count} other catalogue model#{'s' unless child_count == 1}."
      when :child_inside_parent
        "This model is physically nested inside #{parent_count} parent catalogue model#{'s' unless parent_count == 1}."
      else
        "No current parent/child relationship was found. This nesting flag may be stale."
      end
    end
  end
end
