class CatalogQuality::Analyzer
  Result = Struct.new(
    :model,
    :issues,
    :score,
    :status,
    keyword_init: true
  )

  def analyze(model)
    issues = []

    issues << "missing_preview" if missing_preview?(model)
    issues << "missing_caption" if missing_caption?(model)
    issues << "missing_collection" if missing_collection?(model)
    issues << "missing_tags" if missing_tags?(model)
    issues << "poor_name" if poor_name?(model)
    issues << "poor_path" if poor_path?(model)

    score =
      100 - issue_penalty(issues)

    Result.new(
      model: model,
      issues: issues,
      score: [score, 0].max,
      status: status_for(score, issues)
    )
  end

  def summary(scope = Model.all)
    results =
      scope
        .includes(
          :library,
          :collections,
          :tags,
          :preview_file
        )
        .map { |model| analyze(model) }

    {
      total: results.length,
      healthy:
        results.count { |result| result.status == "healthy" },
      needs_attention:
        results.count { |result| result.status == "needs_attention" },
      critical:
        results.count { |result| result.status == "critical" },
      missing_preview:
        results.count { |result| result.issues.include?("missing_preview") },
      missing_caption:
        results.count { |result| result.issues.include?("missing_caption") },
      missing_collection:
        results.count { |result| result.issues.include?("missing_collection") },
      missing_tags:
        results.count { |result| result.issues.include?("missing_tags") },
      poor_name:
        results.count { |result| result.issues.include?("poor_name") }
    }
  end

  private

  def missing_preview?(model)
    return false if model.preview_file.present?

    files =
      model.model_files.to_a

    files.none? do |file|
      file.is_image? ||
        file.is_video? ||
        file.has_render?
    end
  end

  def missing_caption?(model)
    model.caption.blank?
  end

  def missing_collection?(model)
    model.collections.empty?
  end

  def missing_tags?(model)
    model.tags.empty?
  end

  def poor_name?(model)
    name =
      model.name.to_s.strip

    return true if name.blank?
    return true if name.length < 3
    return true if name.match?(/\A[0-9]+\z/)
    return true if name.match?(/\A[0-9a-f-]{20,}\z/i)
    return true if name.casecmp("test").zero?

    false
  end

  def poor_path?(model)
    path =
      model.path.to_s

    return true if path.blank?
    return true if path.match?(%r{\Anew/}i)
    return true if path.match?(/#[0-9]+\z/)

    false
  end

  def issue_penalty(issues)
    penalties = {
      "missing_preview" => 30,
      "missing_caption" => 10,
      "missing_collection" => 15,
      "missing_tags" => 15,
      "poor_name" => 20,
      "poor_path" => 10
    }

    issues.sum do |issue|
      penalties.fetch(issue, 0)
    end
  end

  def status_for(score, issues)
    return "critical" if issues.include?("missing_preview") && score < 60
    return "critical" if score < 50
    return "needs_attention" if score < 90

    "healthy"
  end
end
