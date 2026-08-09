require "net/http"
require "uri"
require "json"

module PreviewEnrichment
  module Providers
    class MyMinifactorySearch < Base
      BASE_URL = "https://www.myminifactory.com"
      SEARCH_PATH = "/api/search"

      MAX_RESULTS = 10
      MAX_QUERIES = 3

      def search
        candidates = search_queries.flat_map do |query|
          perform_search(query)
        rescue StandardError => error
          Rails.logger.warn(
            {
              event: "preview_enrichment_mmf_search_failed",
              provider: "myminifactory",
              model_id: model.id,
              query: query,
              error: error.class.name,
              message: error.message
            }.to_json
          )

          []
        end

        candidates
          .compact
          .uniq { |candidate| candidate.source_page_url }
          .sort_by { |candidate| -candidate.confidence.to_i }
          .first(MAX_RESULTS)
      end

      private

      def search_queries
        PreviewEnrichment::QueryBuilder
          .new(model)
          .queries
          .first(MAX_QUERIES)
          .map { |query| clean_query(query) }
          .reject(&:blank?)
          .uniq
      end

      def clean_query(query)
        query.to_s
          .gsub('"', "")
          .gsub(/\b3D printable model\b/i, "")
          .gsub(/\bSTL\b/i, "")
          .gsub(/\s+/, " ")
          .strip
      end

      def perform_search(query)
        uri = URI("#{BASE_URL}#{SEARCH_PATH}")

        uri.query = URI.encode_www_form(
          object: "1",
          bundle: "1",
          query: query,
          sortBy: "relevance",
          page: "1"
        )

        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] =
          "Mozilla/5.0 (compatible; MakerLibrary3D/1.0)"
        request["Accept"] = "application/json"

        response = Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: true,
          open_timeout: 8,
          read_timeout: 20
        ) do |http|
          http.request(request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise "MyMiniFactory HTTP #{response.code}"
        end

        payload = JSON.parse(response.body)

        records =
          payload["objectResults"] ||
          payload["objects"] ||
          payload["results"] ||
          []

        Array(records).filter_map do |record|
          build_candidate(record, query)
        end
      end

      def build_candidate(record, query)
        title =
          record["name"] ||
          record["title"]

        return nil if title.blank?

        creator =
          record["user_name"] ||
          record["user_username"] ||
          record["username"] ||
          record.dig("user", "username") ||
          record.dig("designer", "username") ||
          record["designer"]

        page_url =
          record["absolute_url"] ||
          record["objectUrl"] ||
          record["link"]

        if page_url.blank?
          id = record["id"]
          slug = record["url"] || record["slug"]

          if slug.present?
            page_url =
              "#{BASE_URL}/object/3d-print-#{slug}"
          elsif id.present?
            page_url =
              "#{BASE_URL}/object/#{id}"
          end
        end

        return nil if page_url.blank?

        page_url =
          "#{BASE_URL}#{page_url}" if page_url.start_with?("/")

        Candidate.new(
          provider: "myminifactory",
          source_page_url: page_url,
          image_url: image_url_for(record),
          title: title.to_s.strip,
          creator: creator.to_s.presence,
          license: license_for(record),
          confidence: confidence_for(
            title: title,
            creator: creator,
            query: query
          ),
          match_method: "myminifactory_api_search",
          metadata: {
            query: query,
            mmf_id: record["id"],
            slug: record["slug"],
            likes: record["likes"] || record["likeCount"],
            views: record["visits"] || record["views"] || record["viewCount"],
            downloads: record["downloads"] || record["downloadCount"],
            price: record["price"],
            premium: record["premium"],
            category: record["category_name"] || record["category"],
            user_id: record["user_id"],
            user_username: record["user_username"],
            user_url: record["user_url"],
            folder_url: record["folderURL"],
            date_published: record["date_published"],
            has_files: record["has_files"],
            has_pdf: record["has_pdf"]
          }
        )
      end

      def image_url_for(record)
        image =
          record["obj_original_img"] ||
          record["obj_img"] ||
          record["image"] ||
          record["image_url"] ||
          record["imageUrl"] ||
          record["thumbnail"] ||
          record["thumbnail_url"] ||
          record["thumbnailUrl"]

        if image.is_a?(Hash)
          image =
            image["url"] ||
            image["src"] ||
            image["original"] ||
            image["thumbnail"]
        end

        return nil if image.blank?

        image = image.to_s

        return image if image.start_with?("http")
        return "#{BASE_URL}#{image}" if image.start_with?("/")

        image
      end

      def license_for(record)
        license = record["license"]

        if license.is_a?(Hash)
          license =
            license["name"] ||
            license["title"] ||
            license["slug"]
        end

        license.to_s.presence
      end

      def confidence_for(title:, creator:, query:)
        model_text = normalized(model.name)
        title_text = normalized(title)
        query_text = normalized(query)

        score = 35

        if title_text == model_text
          score = 95
        elsif title_text == query_text
          score = 92
        else
          model_words = significant_words(model_text)
          title_words = significant_words(title_text)

          overlap = model_words & title_words

          if model_words.any?
            score += (
              overlap.length.to_f /
              model_words.length *
              50
            ).round
          end

          if title_text.include?(model_text) ||
             model_text.include?(title_text)
            score += 15
          end
        end

        creator_text = normalized(creator)

        if creator_hints.any? do |hint|
          creator_text == normalized(hint)
        end
          score += 15
        end

        [[score, 40].max, 99].min
      end

      def creator_hints
        @creator_hints ||= begin
          texts = [
            model.name,
            model.path,
            *model.model_files.map(&:filename)
          ].compact.map(&:to_s)

          texts
            .flat_map do |text|
              text.scan(/@([A-Za-z0-9_.-]+)/).flatten
            end
            .map do |value|
              value.gsub(/\.(stl|3mf|obj)\z/i, "")
            end
            .map(&:strip)
            .reject(&:blank?)
            .uniq
            .first(3)
        end
      end

      def significant_words(text)
        normalized(text)
          .scan(/[a-z0-9]+/)
          .reject { |word| word.length < 3 }
          .reject do |word|
            %w[
              stl
              model
              printable
              presupported
              supported
              version
              file
              files
            ].include?(word)
          end
          .uniq
      end

      def normalized(value)
        value.to_s
          .downcase
          .gsub(/[^a-z0-9]+/, " ")
          .gsub(/\s+/, " ")
          .strip
      end
    end
  end
end
