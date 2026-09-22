module Admin
  class FileStorageController < ApplicationController
    before_action :authenticate_user!
    before_action :require_administrator!

    def index
      skip_policy_scope
      skip_authorization

      @activity_page = Admin::StorageSourceStatus.page(number: params[:activity_page])
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
        with_render: rows.count(&:has_render),
        bytes: rows.sum { |row| row.size.to_i }
      }
      @libraries = Library.order(:name)
      @extensions = ModelFile.where.not(filename: nil).pluck(:filename).filter_map do |filename|
        File.extname(filename).delete(".").downcase.presence
      end.uniq.sort
      @catalogue_file_count = ModelFile.count
      @storage_sources = Admin::StorageSources.call

      @storage_source_statuses =
        Admin::StorageSourceStatus.recent(
          limit: 500
        )

      health_statuses =
        @storage_source_statuses.select do |status|
          status.action.to_s == "health"
        end

      stale_before =
        24.hours.ago

      @storage_health_by_source =
        @storage_sources.each_with_object({}) do |source, result|
          history =
            health_statuses.select do |status|
              status.slug.to_s == source.key.to_s
            end

          latest =
            history.first

          result[source.key.to_s] = {
            latest: latest,
            passed: history.count { |item| item.state.to_s == "passed" },
            failed: history.count { |item| item.state.to_s == "failed" },
            stale:
              latest&.updated_at.present? &&
              latest.updated_at < stale_before,
            attention:
              !source.available ||
              !source.readable ||
              latest&.state.to_s == "failed"
          }
        end

      latest_checks =
        @storage_health_by_source
          .values
          .filter_map do |health|
            health[:latest]&.updated_at
          end

      @storage_health_summary = {
        total: @storage_sources.size,
        healthy:
          @storage_sources.count do |source|
            health =
              @storage_health_by_source[
                source.key.to_s
              ]

            source.available &&
              source.readable &&
              health &&
              health[:latest]&.state.to_s == "passed"
          end,
        attention:
          @storage_sources.count do |source|
            @storage_health_by_source
              .dig(
                source.key.to_s,
                :attention
              )
          end,
        offline:
          @storage_sources.count do |source|
            !source.available
          end,
        latest_check:
          latest_checks.max
      }

      analytics = Admin::FileStorageAnalytics.call
      @library_stats = analytics.libraries
      @extension_stats = analytics.extensions
      @largest_files = analytics.largest_files
      @largest_models = analytics.largest_models
    end


    def anomalies
      skip_policy_scope
      skip_authorization

      result = Admin::FileStorageAnomalies.call

      @zero_byte_files = result.zero_byte_files
      @missing_size_files = result.missing_size_files
      @rare_extensions = result.rare_extensions
      @largest_files = result.largest_files
      @largest_models = result.largest_models
      @libraries = Library.order(:name)

      if params[:compare_library_id].present?
        @comparison_library =
          Library.find(params[:compare_library_id])

        @comparison =
          Admin::PhysicalStorageComparison.call(
            library: @comparison_library
          )
      end
    end


    def reconcile_library
      skip_policy_scope
      skip_authorization

      library = Library.find(params[:library_id])

      library.detect_filesystem_changes_later

      redirect_to(
        admin_file_storage_anomalies_path(
          compare_library_id: library.id
        ),
        notice: "Reconciliation scan queued for #{library.name}. Manyfold will detect changed folders and register discovered files using its native scan pipeline."
      )
    end


    def show_storage_source
      skip_policy_scope
      skip_authorization

      slug = params[:slug].to_s

      @storage_source =
        Admin::StorageSources.call.find do |source|
          source.key.to_s == slug
        end

      unless @storage_source
        redirect_to(
          admin_file_storage_path,
          alert: "Storage source was not found."
        )
        return
      end

      root = @storage_source.container_path.to_s

      @attached_libraries =
        Library
          .where(storage_service: "filesystem")
          .where(
            "path = :root OR path LIKE :prefix",
            root: root,
            prefix: "#{root}/%"
          )
          .order(:name)

      @storage_health_history =
        Admin::StorageSourceStatus
          .recent(limit: 200)
          .select do |status|
            status.slug.to_s == slug &&
              status.action.to_s == "health"
          end
          .first(20)

      @storage_status =
        @storage_health_history.first
    end


    def new_storage_source
      skip_policy_scope
      skip_authorization
      provider = %w[smb azure local].include?(params[:provider]) ? params[:provider] : "smb"
      @storage_source_request = Admin::StorageSourceRequest.new(provider: provider)
    end

    def create_storage_source
      skip_policy_scope
      skip_authorization
      attributes = params.expect(storage_source: [
        :provider, :display_name, :slug, :account_name, :container_name, :account_key,
        :read_only, :server, :share, :username, :password, :domain, :smb_version, :smb_kind
      ])
      @storage_source_request = Admin::StorageSourceRequest.new(attributes.merge(
        action: params[:storage_operation] == "test" ? "test" : "create"
      ))
      request_id = @storage_source_request.enqueue
      if request_id
        redirect_to admin_file_storage_path, notice: "Storage request #{request_id} queued. Refresh Recent Storage Source Activity for the result."
      else
        render :new_storage_source, status: :unprocessable_content
      end
    end

    def run_all_storage_health
      skip_policy_scope
      skip_authorization

      enqueue_storage_request(
        action: "health_all",
        slug: "all"
      )

      redirect_to(
        admin_file_storage_path,
        notice:
          "Storage health check queued for all storage sources. " \
          "Refresh this page in a few seconds."
      )
    end


    def test_storage_source
      skip_policy_scope
      skip_authorization
      Admin::ManagedStorageSource.fetch(params[:slug].to_s)
      Admin::StorageSourceRequest.write_request(action: "health", slug: params[:slug].to_s)
      redirect_to manage_admin_storage_source_path(params[:slug]), notice: "Read-only health check queued. Refresh for the result."
    rescue ArgumentError, KeyError, JSON::ParserError, SystemCallError => error
      redirect_to admin_file_storage_path, alert: "Source is unavailable or protected during this development phase."
    end

    def rename_storage_source
      skip_policy_scope
      skip_authorization
      Admin::ManagedStorageSource.fetch(params[:slug].to_s)
      name = params[:display_name].to_s.strip
      raise ArgumentError unless name.length.between?(1, 80)
      Admin::StorageSourceRequest.write_request(action: "rename", slug: params[:slug].to_s, display_name: name)
      redirect_to manage_admin_storage_source_path(params[:slug]), notice: "Rename queued."
    rescue ArgumentError, KeyError, JSON::ParserError, SystemCallError
      redirect_to admin_file_storage_path, alert: "Rename rejected. Legacy sources remain frozen; names must be 1–80 characters."
    end

    def destroy_storage_source
      skip_policy_scope
      skip_authorization
      queue_managed_lifecycle("remove")
    end

    def reconnect_storage_source
      skip_policy_scope
      skip_authorization
      queue_managed_lifecycle("remount")
    end

    def disconnect_storage_source
      skip_policy_scope
      skip_authorization
      queue_managed_lifecycle("disconnect")
    end

    def register_storage_library
      skip_policy_scope
      skip_authorization
      library = Admin::ManagedStorageSource.register!(params[:slug].to_s)
      redirect_to manage_admin_storage_source_path(params[:slug]), notice: "Library #{library.name} registered. No scan was started."
    rescue ActiveRecord::RecordInvalid => error
      redirect_to admin_file_storage_path, alert: error.record.errors.full_messages.join(". ")
    rescue ArgumentError => error
      redirect_to admin_file_storage_path, alert: error.message
    rescue KeyError, JSON::ParserError, SystemCallError
      redirect_to admin_file_storage_path, alert: "Source is unavailable or protected."
    end

    def clear_storage_activity
      skip_policy_scope
      skip_authorization
      slug = params[:slug].presence
      count = Admin::ManagedStorageSource.with_lock do
        Admin::StorageSourceStatus.clear_completed!(slug: slug)
      end
      destination = slug ? manage_admin_storage_source_path(slug) : admin_file_storage_path(anchor: "storage-activity")
      redirect_to destination, notice: "Cleared #{count} completed activity entries. In-progress entries were kept."
    rescue ArgumentError => error
      redirect_to admin_file_storage_path, alert: error.message
    rescue SystemCallError, IOError
      redirect_to admin_file_storage_path, alert: "History could not be fully cleared. Refresh and retry."
    end

    private

    def queue_managed_lifecycle(action)
      Admin::ManagedStorageSource.with_lock do
        data = Admin::ManagedStorageSource.fetch(params[:slug].to_s)
        root = data.fetch("container_path")
        used = Library.where(storage_service: "filesystem").pluck(:path).any? do |path|
          path == root || path.start_with?(root + "/") || root.start_with?(path + "/")
        end
        raise ArgumentError, "Disconnect, reconnect and removal are blocked while a library uses this source" if used
        Admin::StorageSourceRequest.write_request(action: action, slug: params[:slug].to_s)
      end
      redirect_to admin_file_storage_path, notice: "Storage operation queued. Source files will not be deleted."
    rescue ArgumentError => error
      redirect_to admin_file_storage_path, alert: error.message
    rescue KeyError, JSON::ParserError, SystemCallError
      redirect_to admin_file_storage_path, alert: "Source is unavailable or protected."
    end

    def enqueue_storage_request(payload)
      Admin::StorageSourceRequest.write_request(payload)
    end

    def require_administrator!
      return if current_user&.is_administrator?

      head :forbidden
    end
  end
end
