module Admin
  class NestingProblemIgnorer
    Result = Struct.new(:problem_id, :model_id, :model_name, keyword_init: true)

    def self.call(problem_id:)
      new(problem_id: problem_id).call
    end

    def initialize(problem_id:)
      @problem_id = problem_id.to_i
    end

    def call
      problem = Problem.including_ignored.find_by(id: @problem_id)
      raise ArgumentError, "Nesting problem was not found." unless problem
      raise ArgumentError, "Selected problem is not a nesting problem." unless problem.category == "nesting"
      raise ArgumentError, "Selected nesting problem is not attached to a Model." unless problem.problematic_type == "Model"

      model = problem.problematic
      raise ArgumentError, "The model for this nesting problem no longer exists." unless model.is_a?(Model)

      problem.update!(ignored: true)

      Result.new(
        problem_id: problem.id,
        model_id: model.id,
        model_name: model.name
      )
    end
  end
end
