module Admin
  class IntegrityController < ApplicationController
    before_action :authenticate_user!
    before_action :require_administrator!

    def index
      skip_policy_scope
      skip_authorization
      @report = Admin::IntegrityAnalyzer.call
    end

    def preview
      skip_policy_scope
      skip_authorization

      @preview = Admin::IntegrityPreview.call(params[:category])
    rescue ArgumentError
      redirect_to admin_integrity_path, alert: "Preview is not available for that integrity category."
    end

    def duplicate_sets
      skip_policy_scope
      skip_authorization
      @report = Admin::DuplicateSetAnalyzer.call
    end

    def nesting
      skip_policy_scope
      skip_authorization
      @report = Admin::NestingAnalyzer.call
    end

    def nesting_merge_preview
      skip_policy_scope
      skip_authorization
      @preview = Admin::NestingMergePreview.call(
        parent_id: params[:parent_id],
        child_id: params[:child_id]
      )
    rescue ArgumentError => error
      redirect_to admin_integrity_nesting_path, alert: error.message
    end

    def clear_stale
      skip_authorization

      result = Admin::IntegrityStaleCleaner.call(params[:category])
      message = "Checked #{result.checked} #{result.category.humanize.downcase} problem(s); cleared #{result.cleared} verified stale flag(s); skipped #{result.skipped}."
      message += " #{result.errors.size} error(s) were left untouched." if result.errors.any?

      redirect_to admin_integrity_preview_path(result.category),
        notice: message
    rescue ArgumentError
      redirect_to admin_integrity_path,
        alert: "Stale cleanup is not available for that integrity category."
    end

    def remove_missing_records
      skip_authorization

      selected = params[:problem_ids]
      if selected.blank?
        redirect_to admin_integrity_preview_path("missing"), alert: "Select at least one confirmed missing record."
        return
      end

      result = Admin::MissingRecordRemover.call(selected)
      message = "Requested #{result.requested}; removed #{result.removed} confirmed missing database record(s); skipped #{result.skipped}."
      message += " Cleared #{result.preview_refs_cleared} preview reference(s)." if result.preview_refs_cleared.positive?
      message += " Cleared #{result.entrypoint_refs_cleared} entrypoint reference(s)." if result.entrypoint_refs_cleared.positive?
      message += " #{result.errors.size} error(s) were left untouched." if result.errors.any?

      redirect_to admin_integrity_preview_path("missing"), notice: message
    end

    def remove_duplicates
      skip_authorization

      canonical_id = params[:canonical_id]
      remove_ids = params[:remove_ids]

      if canonical_id.blank? || remove_ids.blank?
        redirect_to admin_integrity_duplicate_sets_path,
          alert: "Select one canonical copy and at least one same-model duplicate to remove."
        return
      end

      result = Admin::DuplicateRecordRemover.call(
        canonical_id: canonical_id,
        remove_ids: remove_ids
      )

      message = "Canonical ModelFile ##{result.canonical_id}: requested #{result.requested}; removed #{result.removed} verified same-model duplicate(s); skipped #{result.skipped}."
      message += " Moved #{result.preview_refs_moved} preview reference(s)." if result.preview_refs_moved.positive?
      message += " Moved #{result.entrypoint_refs_moved} entrypoint reference(s)." if result.entrypoint_refs_moved.positive?
      message += " #{result.errors.size} error(s) were left untouched." if result.errors.any?

      redirect_to admin_integrity_duplicate_sets_path, notice: message
    rescue ArgumentError => error
      redirect_to admin_integrity_duplicate_sets_path, alert: error.message
    end

    private

    def require_administrator!
      return if current_user&.is_administrator?

      head :forbidden
    end
  end
end
