module PreviewEnrichment
  class Eligibility
    def initialize(model)
      @model = model
    end

    def eligible?
      local_model? &&
        has_3d_files? &&
        no_real_images?
    end

    def reason
      return :remote_model unless local_model?
      return :no_3d_files unless has_3d_files?
      return :already_has_images unless no_real_images?

      :missing_real_images
    end

    private

    attr_reader :model

    def local_model?
      !model.remote?
    end

    def has_3d_files?
      model.three_d_files.any?
    end

    def no_real_images?
      model.image_files.empty?
    end
  end
end
