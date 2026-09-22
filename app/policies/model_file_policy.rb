class ModelFilePolicy < ApplicationPolicy
  def show?
    return false unless @user
    return true if @user.is_moderator?
    return false unless @user.membership_access_active?
    return false unless ModelPolicy.new(@user, @record.model).show?

    @record.previewable? ||
      check_permissions(
        @record.model,
        ["view", "edit", "own"],
        @user
      )
  end

  def raw?
    show?
  end

  def print?
    all_of(
      @user&.is_printer?,
      none_of(
        SiteSettings.demo_mode_enabled?
      )
    )
  end

  def create?
    @user&.is_contributor? &&
      can_update_model?
  end

  def convert?
    can_update_model? && @record.convertable? && !@record.problems.exists?(category: :non_manifold)
  end

  def update?
    can_update_model?
  end

  def destroy?
    can_update_model?
  end

  def bulk_edit?
    bulk_update?
  end

  def bulk_update?
    can_update_model?
  end

  class Scope < ApplicationPolicy::Scope
    FULL_VIEW_PERMISSIONS = ["view", "edit", "own"]

    def resolve
      return scope if @user&.is_moderator?
      return scope.none unless @user
      return scope.none unless @user.membership_access_active?

      subject_list =
        [
          nil,
          user,
          user&.roles
        ].flatten

      result =
        scope
          .where(previewable: true)
          .where(
            model:
              Model.granted_to(
                "preview",
                subject_list
              )
          )
          .where.not(
            model:
              Model.granted_to(
                FULL_VIEW_PERMISSIONS,
                subject_list
              )
          )
          .or(
            scope.where(
              model:
                Model.granted_to(
                  FULL_VIEW_PERMISSIONS,
                  subject_list
                )
            )
          )

      plan =
        @user.membership_plan

      return result.none unless plan&.active?
      return result if plan.all_libraries?

      result.where(
        model_id:
          Model
            .where(
              library_id: plan.library_ids
            )
            .select(:id)
      )
    end
  end

  private

  def can_update_model?
    ModelPolicy.new(@user, @record.model).update?
  end
end
