class ModelPolicy < ApplicationPolicy
  def show?
    return super if user&.is_moderator?
    return false unless entitled_to_model_library?

    super &&
      !(
        user&.sensitive_content_handling == "hide" &&
        record.sensitive
      )
  end

  def configure_merge?
    merge?
  end

  def merge?
    all_of(
      update?,
      none_of(
        SiteSettings.demo_mode_enabled?
      )
    )
  end

  def upload?
    edit? &&
      UploadPolicy.new(
        user,
        record
      ).create?
  end

  def download?
    return true if user&.is_moderator?
    return false unless entitled_to_model_library?

    check_permissions(
      record,
      ["view", "edit", "own"],
      user
    )
  end

  def destroy?
    super &&
      (
        record.is_a?(Model) ?
          !record.contains_other_models? :
          true
      )
  end

  def scan?
    user&.is_moderator?
  end

  def sync?
    update?
  end

  def organize?
    edit?
  end

  def bulk_edit?
    user&.is_moderator?
  end

  def bulk_update?
    user&.is_moderator?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      base =
        if user&.sensitive_content_handling == "hide"
          super.where(
            sensitive: false
          )
        else
          super
        end

      return base if user&.is_moderator?
      return base.none unless user
      return base.none unless user.membership_access_active?

      plan =
        user.membership_plan

      return base.none unless plan&.active?
      return base if plan.all_libraries?

      base.where(
        library_id: plan.library_ids
      )
    end
  end

  private

  def entitled_to_model_library?
    return false unless user
    return false unless record.respond_to?(:library)

    user.entitled_to_library?(
      record.library
    )
  end
end
