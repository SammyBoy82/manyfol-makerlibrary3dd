class Settings::MembershipPlansController < ApplicationController
  before_action :require_administrator!
  before_action :get_plan,
    only: [:update, :destroy]

  def index
    skip_policy_scope
    skip_authorization

    @plans =
      MembershipPlan
        .includes(:libraries, :users)
        .order(:name)

    @libraries =
      Library.order(:name)

    render layout: "settings"
  end

  def create
    skip_policy_scope
    skip_authorization

    plan =
      MembershipPlan.new(
        plan_params
      )

    if plan.save
      update_libraries(
        plan
      )

      AdminAudit.record(
        actor: current_user,
        action: "membership_plan_created",
        target: plan,
        request: request,
        after_data: plan_audit_snapshot(plan)
      )

      redirect_to(
        settings_membership_plans_path,
        notice:
          "Membership plan created."
      )
    else
      redirect_to(
        settings_membership_plans_path,
        alert:
          plan.errors.full_messages.join(", ")
      )
    end
  end

  def update
    skip_policy_scope
    skip_authorization

    before_state =
      plan_audit_snapshot(@plan)

    if @plan.update(plan_params)
      update_libraries(
        @plan
      )

      AdminAudit.record(
        actor: current_user,
        action: "membership_plan_updated",
        target: @plan,
        request: request,
        before_data: before_state,
        after_data: plan_audit_snapshot(@plan)
      )

      redirect_to(
        settings_membership_plans_path,
        notice:
          "#{@plan.name} updated."
      )
    else
      redirect_to(
        settings_membership_plans_path,
        alert:
          @plan.errors.full_messages.join(", ")
      )
    end
  end

  def destroy
    skip_policy_scope
    skip_authorization

    if @plan.users.exists?
      redirect_to(
        settings_membership_plans_path,
        alert:
          "This plan cannot be deleted while members are assigned to it."
      )
      return
    end

    before_state =
      plan_audit_snapshot(@plan)

    target_name =
      @plan.name

    target_id =
      @plan.id

    @plan.destroy!

    AdminAudit.record(
      actor: current_user,
      action: "membership_plan_deleted",
      request: request,
      before_data: before_state,
      context: {
        target_type: "MembershipPlan",
        target_id: target_id,
        target_name: target_name
      }
    )

    redirect_to(
      settings_membership_plans_path,
      notice:
        "Membership plan deleted."
    )
  end

  private

  def plan_audit_snapshot(plan)
    {
      name: plan.name,
      active: plan.active?,
      all_libraries: plan.all_libraries?,
      billing_interval: plan.billing_interval,
      library_ids: plan.library_ids.sort,
      libraries: plan.libraries.order(:name).pluck(:name),
      assigned_members: plan.users.count
    }
  end

  def require_administrator!
    raise Pundit::NotAuthorizedError unless current_user&.is_administrator?
  end

  def get_plan
    @plan =
      MembershipPlan.find(
        params[:id]
      )
  end

  def plan_params
    params.expect(
      membership_plan: [
        :name,
        :description,
        :billing_interval,
        :active,
        :all_libraries,
        :stripe_product_id,
        :stripe_price_id
      ]
    )
  end

  def update_libraries(plan)
    if plan.all_libraries?
      plan.library_ids = []
      return
    end

    ids =
      Array(
        params.dig(
          :membership_plan,
          :library_ids
        )
      )
        .reject(&:blank?)
        .map(&:to_i)

    plan.library_ids =
      Library
        .where(id: ids)
        .pluck(:id)
  end
end
