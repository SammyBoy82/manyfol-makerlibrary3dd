require "net/http"
require "uri"
require "json"
require "cgi"

module PreviewEnrichment
  module Providers
    class ThangsSearch < Base
      BASE_URL = "https://thangs.com"
      MAX_RESULTS = 10
      MAX_QUERIES = 3

      def search
        candidates = search_queries.flat_map do |query|
          search_thangs(query)
        rescue StandardError => error
          Rails.logger.warn(
            {
              event: "preview_enrichment_thangs_search_failed",
              provider: "thangs",
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

      def search_thangs(query)
        uri = URI(
          "#{BASE_URL}/search/#{CGI.escape(query).gsub("+", "%20")}"
        )

        uri.query = URI.encode_www_form(
          scope: "thangs",
          view: "list"
        )

        html = fetch_html(uri)

        return [] if html.blank?

        data = extract_next_data(html)

        return [] unless data

        models = find_model_records(data)

        models.filter_map do |record|
          build_candidate(record, query)
        end
      end

      def fetch_html(uri)
        request = Net::HTTP::Get.new(uri)

        request["User-Agent"] =
          "Mozilla/5.0 (compatible; MakerLibrary3D/1.0)"

        request["Accept"] =
          "text/html,application/xhtml+xml"

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
          raise "Thangs HTTP #{response.code}"
        end

        response.body.to_s
      end

      def extract_next_data(html)
        match = html.match(
          /<script[^>]+id=["']__NEXT_DATA__["'][^>]*>(.*?)<\/script>/mi
        )

        return nil unless match

        JSON.parse(
          CGI.unescapeHTML(match[1])
        )
      end

      def find_model_records(value, found = [])
        case value
        when Hash
          if thangs_model_record?(value)
            found << value
          end

          value.each_value do |child|
            find_model_records(child, found)
          end

        when Array
          value.each do |child|
            find_model_records(child, found)
          end
        end

        found.uniq { |record| record["modelId"].to_s }
      end

      def thangs_model_record?(value)
        value.is_a?(Hash) &&
          value["modelId"].present? &&
          value["name"].present? &&
          (
            value["modelPageUrl"].present? ||
            value["site"].to_s == "thangs"
          )
      end

      def build_candidate(record, query)
        title = record["name"].to_s.strip
        creator = record["ownerUsername"].to_s.strip

        page_url =
          record["modelPageUrl"].presence ||
          "#{BASE_URL}/m/#{record["modelId"]}"

        image_url = preferred_image(record)

        return nil if title.blank?
        return nil if page_url.blank?

        Candidate.new(
          provider: "thangs",
          source_page_url: page_url,
          image_url: image_url,
          title: title,
          creator: creator.presence,
          license: nil,
          confidence: confidence_for(
            title: title,
            creator: creator,
            query: query
          ),
          match_method: "thangs_next_data_search",
          metadata: {
            query: query,
            model_id: record["modelId"],
            visibility: record["visibility"],
            tags: record["tags"],
            categories: record["categories"],
            download_count: record["downloadCount"],
            likes_count: record["likesCount"]
          }
        )
      end

      def preferred_image(record)
        record["thumbnailUrl"].presence ||
          Array(record["thumbnails"]).first.presence ||
          attachment_image(record)
      end

      def attachment_image(record)
        attachments = Array(record["attachments"])

        owner_image =
          attachments.find do |attachment|
            attachment["uploadedByModelOwner"] == true &&
              attachment["isApproved"] != false
          end

        attachment = owner_image || attachments.first

        return nil unless attachment

        attachment["enhancedImageUrl"].presence ||
          attachment["imageUrl"].presence
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
            ratio = overlap.length.to_f / model_words.length
            score += (ratio * 50).round
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
