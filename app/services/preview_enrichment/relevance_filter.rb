module PreviewEnrichment
  class RelevanceFilter
    MAX_PER_PROVIDER = 2
    MAX_PER_MODEL = 5

    GENERIC_WORDS = %w[
      3d
      stl
      obj
      3mf
      model
      models
      printable
      print
      printing
      file
      files
      presupported
      supported
      support
      version
      miniature
      miniatures
      figure
      figurine
      statue
      toy
      object
      design
      pack
      collection
      set
      download
    ].freeze

    def initialize(model, candidates)
      @model = model
      @candidates = Array(candidates)
    end

    def call
      scored = candidates.filter_map do |candidate|
        evaluate(candidate)
      end

      # First limit each provider so one noisy provider
      # cannot dominate the entire review queue.
      provider_limited =
        scored
          .group_by { |entry| entry[:candidate].provider.to_s }
          .flat_map do |_provider, entries|
            entries
              .sort_by { |entry| -entry[:score] }
              .first(MAX_PER_PROVIDER)
          end

      provider_limited
        .sort_by { |entry| -entry[:score] }
        .first(MAX_PER_MODEL)
        .map { |entry| rebuild_candidate(entry) }
    end

    private

    attr_reader :model, :candidates

    def evaluate(candidate)
      # A source-page candidate originating from a URL already attached
      # to the Manyfold model is trusted evidence.
      if candidate.match_method == "trusted_source_page_metadata"
        return {
          candidate: candidate,
          score: [candidate.confidence.to_i, 96].max,
          relevance: 100,
          overlap: [],
          required_overlap: 0
        }
      end

      title = candidate.title.to_s

      return nil if title.blank?

      model_text = normalized(model.name)
      title_text = normalized(title)

      return nil if model_text.blank? || title_text.blank?

      model_words = significant_words(model_text)
      title_words = significant_words(title_text)

      # If everything was stripped as generic terminology,
      # fall back to normal non-trivial words.
      if model_words.empty?
        model_words = fallback_words(model_text)
      end

      if title_words.empty?
        title_words = fallback_words(title_text)
      end

      return nil if model_words.empty? || title_words.empty?

      overlap = model_words & title_words

      phrase_match =
        title_text == model_text ||
        title_text.include?(model_text) ||
        model_text.include?(title_text)

      required_overlap = minimum_required_overlap(model_words.length)

      # Hard relevance gate.
      #
      # Examples:
      #   "Bulldog The Boss" -> needs bulldog + boss
      #   "Bengal Tiger And Cub" -> needs at least 2 strong terms
      #
      # Exact/contained phrase matches bypass this count.
      unless phrase_match
        return nil if overlap.length < required_overlap
      end

      coverage =
        overlap.length.to_f /
        model_words.length

      precision =
        overlap.length.to_f /
        [title_words.length, 1].max

      relevance =
        (
          (coverage * 65) +
          (precision * 20)
        ).round

      relevance += 20 if phrase_match
      relevance += creator_bonus(candidate)

      relevance = relevance.clamp(0, 100)

      # Provider confidence is useful evidence, but actual title
      # relevance now has substantially more weight.
      provider_score = candidate.confidence.to_i.clamp(0, 100)

      final_score =
        (
          relevance * 0.75 +
          provider_score * 0.25
        ).round.clamp(0, 99)

      # Do not persist mediocre matches.
      return nil if final_score < 78

      {
        candidate: candidate,
        score: final_score,
        relevance: relevance,
        overlap: overlap,
        required_overlap: required_overlap
      }
    end

    def rebuild_candidate(entry)
      candidate = entry[:candidate]

      metadata =
        (candidate.metadata || {}).merge(
          relevance_score: entry[:relevance],
          relevance_overlap: entry[:overlap],
          relevance_required_overlap: entry[:required_overlap],
          original_provider_confidence: candidate.confidence
        )

      candidate.class.new(
        **candidate.to_h.merge(
          confidence: entry[:score],
          metadata: metadata
        )
      )
    end

    def minimum_required_overlap(word_count)
      case word_count
      when 0
        0
      when 1
        1
      when 2
        2
      when 3
        2
      else
        (word_count * 0.60).ceil
      end
    end

    def creator_bonus(candidate)
      expected =
        [
          model.creator&.name,
          *creator_hints
        ]
          .compact
          .map { |value| normalized(value) }
          .reject(&:blank?)
          .uniq

      return 0 if expected.empty?

      actual = normalized(candidate.creator)

      return 0 if actual.blank?

      if expected.include?(actual)
        12
      elsif expected.any? do |value|
        actual.include?(value) ||
          value.include?(actual)
      end
        8
      else
        0
      end
    end

    def creator_hints
      texts = [
        model.name,
        model.path,
        *model.model_files.map(&:filename)
      ].compact.map(&:to_s)

      texts
        .flat_map do |text|
          text.scan(/@([A-Za-z0-9_.-]+)/).flatten
        end
        .map { |value| value.gsub(/\.(stl|3mf|obj)\z/i, "") }
        .map(&:strip)
        .reject(&:blank?)
        .uniq
        .first(3)
    end

    def significant_words(value)
      fallback_words(value)
        .reject { |word| GENERIC_WORDS.include?(word) }
    end

    def fallback_words(value)
      normalized(value)
        .scan(/[a-z0-9]+/)
        .reject { |word| word.length < 3 }
        .uniq
    end

    def normalized(value)
      value.to_s
        .downcase
        .tr("_-", " ")
        .gsub(/[^a-z0-9]+/, " ")
        .gsub(/\s+/, " ")
        .strip
    end
  end
end
