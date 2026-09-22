module Admin
  class FileStorageController < ApplicationController
    before_action :authenticate_user!
    before_action :require_administrator!

    def index
      skip_policy_scope
      skip_authorization

      @query = params[:q].to_s.strip
      @library_id = params[:library_id].presence
      @extension = params[:extension].to_s.strip.downcase.presence
      @source_state = params[:source_state].presence

      scope = ModelFile.joins(model: :library).order("libraries.name ASC, models.name ASC, model_files.filename ASC")
      scope = scope.where(models: {library_id: @library_id}) if @library_id

      if @query.present?
        like = "%#{ModelFile.sanitize_sql_like(@query)}%"
        scope = scope.where("models.name ILIKE :q OR model_files.filename ILIKE :q OR models.path ILIKE :q", q: like)
      end

      scope = scope.where("LOWER(model_files.filename) LIKE ?", "%.#{@extension}") if @extension.present?

      result = Admin::FileStorageInventory.call(scope: scope, limit: 250)
      rows = result.rows
      rows = rows.select(&:source_exists) if @source_state == "present"
      rows = rows.reject(&:source_exists) if @source_state == "missing"

      @rows = rows
      @summary = {
        shown: rows.size,
        source_present: rows.count(&:source_exists),
        source_missing: rows.count { |row| !row.source_exists },
        with_digest: rows.count { |row| row.digest.present? },
        with_render: rows.count(&:has_render),
        bytes: rows.sum { |row| row.size.to_i }
      }
      @libraries = Library.order(:name)
      @extensions = ModelFile.where.not(filename: nil).pluck(:filename).filter_map do |filename|
        File.extname(filename).delete(".").downcase.presence
      end.uniq.sort
      @catalogue_file_count = ModelFile.count
    end

    private

    def require_administrator!
      return if current_user&.is_administrator?

      head :forbidden
    end
  end
end
