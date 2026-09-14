module PreviewEnrichment
  class SearchContext
    GENERIC_NAMES = %w[
      accessories
      accessory
      standard
      manual
      monocolor
      multicolor
      alternate
      version
      parts
      part
      files
      file
      extras
      extra
      bonus
      support
      supports
      supported
      presupported
      base
      bases
      test
      example
      samples
      sample
      misc
      miscellaneous
      other
      model
      models
      object
      objects
    ].freeze

    GENERIC_PHRASES = [
      "book nook",
      "alternate version",
      "alternate version for lighting",
      "standard version",
      "presupported version",
      "supported version"
    ].freeze

    def initialize(model)
      @model = model
    end

    def search_name
      return normalized_display_name unless generic_name?

      contextual_name
    end

    def searchable?
      value = search_name

      return false if value.blank?

      meaningful_words(value).length >= 2
    end

    def generic_name?
      name = normalized(model.name)

      return true if name.blank?
      return true if GENERIC_PHRASES.include?(name)

      words = meaningful_words(name)

      return true if words.empty?

      words.all? do |word|
        GENERIC_NAMES.include?(word)
      end
    end

    def evidence
      {
        original_name: model.name,
        search_name: search_name,
        generic_name: generic_name?,
        searchable: searchable?,
        path_context: path_context,
        filename_context: filename_context,
        creator: model.creator&.name,
        tags: model.tag_list
      }
    end

    private

    attr_reader :model

    def contextual_name
      candidates = []

      candidates.concat(path_context)
      candidates.concat(filename_context)

      candidates << model.creator&.name

      candidates.concat(Array(model.tag_list))

      terms =
        candidates
          .compact
          .flat_map { |value| meaningful_words(value) }
          .reject { |word| GENERIC_NAMES.include?(word) }
          .uniq

      return nil if terms.empty?

      terms.first(6).join(" ")
    end

    def path_context
      value = model.path.to_s

      return [] if value.blank?

      value
        .split("/")
        .map(&:strip)
        .reject(&:blank?)
        .reverse
        .first(4)
        .reject do |part|
          normalized(part) == normalized(model.name)
        end
    end

    def filename_context
      model.three_d_files
        .map(&:basename)
        .map do |filename|
          filename
            .to_s
            .gsub(/[_-]+/, " ")
            .gsub(/\b(obj|stl|3mf|supported|presupported)\b/i, " ")
            .squish
        end
        .reject(&:blank?)
        .first(5)
    end

    def normalized_display_name
      model.name.to_s
        .tr("_-", " ")
        .squish
    end

    def meaningful_words(value)
      normalized(value)
        .scan(/[a-z0-9]+/)
        .reject { |word| word.length < 3 }
        .reject do |word|
          %w[
            stl
            obj
            3mf
            model
            printable
            printing
            file
            files
          ].include?(word)
        end
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
