class Settings::UsersController < ApplicationController
  before_action :get_user, except: [:index, :new, :create]
  before_action :get_available_roles, only: [:new, :create, :edit, :update]
  respond_to :html

  def index
    @query = params[:q].to_s.strip
    @access_filter = params[:access].to_s
    @role_filter = params[:role].to_s

    @users =
      policy_scope(User)
        .active
        .includes(:roles)

    if @query.present?
      like =
        "%#{User.sanitize_sql_like(@query)}%"

      @users =
        @users.where(
          "users.username ILIKE :q OR users.email ILIKE :q",
          q: like
        )
    end

    case @access_filter
    when "active"
      @users =
        @users
          .where(
            approved: true,
            membership_status: "active"
          )
          .where(
            "membership_expires_at IS NULL OR membership_expires_at > ?",
            Time.current
          )

    when "expired"
      @users =
        @users
          .where(
            membership_status: "active"
          )
          .where(
            "membership_expires_at IS NOT NULL AND membership_expires_at <= ?",
            Time.current
          )

    when "suspended"
      @users =
        @users.where(
          "membership_status = ? OR approved = ?",
          "suspended",
          false
        )
    end

    if %w[
      member
      contributor
      moderator
      administrator
      printer
    ].include?(@role_filter)
      @users =
        @users
          .joins(:roles)
          .where(
            roles: {
              name: @role_filter
            }
          )
          .distinct
    end

    @users = apply_sort_order(@users)

    @users =
      @users
        .page(params[:page]&.to_i || 1)
        .per(params[:per_page]&.to_i || 25)

    render layout: "settings"
  end

  def show
    render layout: "settings"
  end

  def new
    authorize(User)
    @user = User.new
    @user.send :assign_default_role
    render layout: "settings"
  end

  def edit
    render layout: "settings"
  end

  def create
    authorize(User)
    password = helpers.random_password
    # Create user with a random password if one isn't provided
    @user = User.create({
      "password" => password,
      "password_confirmation" => password,
      "quota" => SiteSettings.default_user_quota,
      "quota_use_site_default" => true
    }.merge(user_params))
    if @user.valid?
      AdminAudit.record(
        actor: current_user,
        action: "member_created",
        target: @user,
        request: request,
        after_data: membership_audit_snapshot(@user)
      )

      @user.send_reset_password_instructions if SiteSettings.email_configured?
      redirect_to [:settings, @user], notice: t(".success")
    else
      render :new, layout: "settings", status: :unprocessable_content
    end
  end

  def update
    if @user.is_administrator? &&
        !current_user&.is_administrator?

      redirect_to(
        settings_users_path,
        alert: "Only an administrator can modify an administrator account."
      )
      return
    end

    if params[:reset]
      @user.send_reset_password_instructions
      redirect_to [:settings, @user], notice: t(".reset_link_sent")
    elsif params[:approve]
      @user.update(approved: true)
      UserMailer.with(user: @user).account_approved.deliver_later if SiteSettings.email_configured?
      redirect_to [:settings, @user], notice: t(".approved")
    elsif @user.update(user_params)
      redirect_to [:settings, @user], notice: t(".success")
    else
      render :edit, layout: "settings", status: :unprocessable_content
    end
  end

  def enable_access
    require_membership_administrator!

    before_state = membership_audit_snapshot(@user)

    @user.add_role(:member)

    @user.update!(
      approved: true,
      membership_status: "active",
      membership_started_at:
        @user.membership_started_at ||
        Time.current
    )

    AdminAudit.record(
      actor: current_user,
      action: "member_access_enabled",
      target: @user,
      request: request,
      before_data: before_state,
      after_data: membership_audit_snapshot(@user)
    )

    redirect_to(
      settings_users_path,
      notice: "Member access enabled for #{@user.username}."
    )
  end

  def disable_access
    require_membership_administrator!

    before_state = membership_audit_snapshot(@user)

    if @user == current_user
      redirect_to(
        settings_users_path,
        alert: "You cannot disable your own account."
      )
      return
    end

    if @user.is_administrator?
      redirect_to(
        settings_users_path,
        alert:
          "Administrator access must be changed before this account can be disabled."
      )
      return
    end

    @user.update!(
      approved: false,
      membership_status: "suspended"
    )

    AdminAudit.record(
      actor: current_user,
      action: "member_access_disabled",
      target: @user,
      request: request,
      before_data: before_state,
      after_data: membership_audit_snapshot(@user)
    )

    redirect_to(
      settings_users_path,
      notice: "Member access disabled for #{@user.username}."
    )
  end

  def update_membership
    require_membership_administrator!

    before_state = membership_audit_snapshot(@user)

    status =
      params[:membership_status].to_s

    unless User::MEMBERSHIP_STATUSES.include?(status)
      redirect_to(
        settings_users_path,
        alert: "Invalid membership status."
      )
      return
    end

    if @user == current_user &&
        status == "suspended"

      redirect_to(
        settings_users_path,
        alert: "You cannot suspend your own account."
      )
      return
    end

    started_at =
      params[:membership_started_at].presence

    expires_at =
      params[:membership_expires_at].presence

    plan =
      if params[:membership_plan_id].present?
        MembershipPlan.find(
          params[:membership_plan_id]
        )
      end

    @user.update!(
      membership_status: status,
      membership_started_at: started_at,
      membership_expires_at: expires_at,
      membership_admin_notes:
        params[:membership_admin_notes].to_s,
      membership_plan: plan,
      approved:
        status == "active"
    )

    AdminAudit.record(
      actor: current_user,
      action: "membership_updated",
      target: @user,
      request: request,
      before_data: before_state,
      after_data: membership_audit_snapshot(@user)
    )

    redirect_to(
      settings_users_path,
      notice:
        "Membership updated for #{@user.username}."
    )
  end


  def extend_membership
    require_membership_administrator!

    before_state = membership_audit_snapshot(@user)

    days =
      params[:days].to_i

    unless [30, 90, 365].include?(days)
      redirect_to(
        settings_users_path,
        alert: "Invalid membership extension."
      )
      return
    end

    base =
      if @user.membership_expires_at.present? &&
          @user.membership_expires_at > Time.current
        @user.membership_expires_at
      else
        Time.current
      end

    @user.add_role(:member)

    @user.update!(
      approved: true,
      membership_status: "active",
      membership_started_at:
        @user.membership_started_at ||
        Time.current,
      membership_expires_at:
        base + days.days
    )

    AdminAudit.record(
      actor: current_user,
      action: "membership_extended",
      target: @user,
      request: request,
      before_data: before_state,
      after_data: membership_audit_snapshot(@user),
      context: {
        days: days
      }
    )

    redirect_to(
      settings_users_path,
      notice:
        "#{@user.username} membership extended by #{days} days."
    )
  end


  def set_role
    require_membership_administrator!

    before_state = membership_audit_snapshot(@user)

    requested =
      params[:membership_role].to_s

    allowed =
      %w[
        member
        contributor
        moderator
        administrator
      ]

    unless allowed.include?(requested)
      redirect_to(
        settings_users_path,
        alert: "Invalid membership role."
      )
      return
    end

    if @user == current_user &&
        @user.is_administrator? &&
        requested != "administrator"

      redirect_to(
        settings_users_path,
        alert: "You cannot remove your own administrator role."
      )
      return
    end

    if @user.is_administrator? &&
        requested != "administrator" &&
        User.with_role(:administrator).count <= 1

      redirect_to(
        settings_users_path,
        alert: "The last administrator cannot be demoted."
      )
      return
    end

    @user.add_role(:member)

    %i[
      contributor
      moderator
      administrator
    ].each do |role|
      @user.remove_role(role)
    end

    @user.add_role(requested.to_sym) unless requested == "member"

    AdminAudit.record(
      actor: current_user,
      action: "member_role_changed",
      target: @user,
      request: request,
      before_data: before_state,
      after_data: membership_audit_snapshot(@user),
      context: {
        requested_role: requested
      }
    )

    redirect_to(
      settings_users_path,
      notice:
        "#{@user.username} membership role changed to #{requested.humanize}."
    )
  end

  def destroy
    @user.destroy
    redirect_to settings_users_path, notice: t(".success")
  end

  private

  def membership_audit_snapshot(user)
    {
      username: user.username,
      approved: user.approved?,
      roles: user.roles.pluck(:name).sort,
      membership_status: user.membership_status,
      membership_started_at:
        user.membership_started_at&.iso8601,
      membership_expires_at:
        user.membership_expires_at&.iso8601,
      membership_plan_id:
        user.membership_plan_id,
      membership_plan:
        user.membership_plan&.name
    }
  end

  def require_membership_administrator!
    return if current_user&.is_administrator?

    raise Pundit::NotAuthorizedError
  end

  def get_available_roles
    @available_roles = policy_scope(Role).all
  end

  def get_user
    @user =
      policy_scope(User)
        .find_param(params[:id])

    membership_actions = %w[
      enable_access
      disable_access
      set_role
      update_membership
      extend_membership
    ]

    if membership_actions.include?(action_name)
      authorize @user, :update?
    else
      authorize @user
    end
  end

  def user_params
    filtered = params.expect(
      user: [
        :email, # i18n-tasks-use t("activerecord.attributes.user.email")
        :username, # i18n-tasks-use t("activerecord.attributes.user.username")
        :password, # i18n-tasks-use t("activerecord.attributes.user.password")
        :password_confirmation, # i18n-tasks-use t("activerecord.attributes.user.password_confirmation")
        :quota, # i18n-tasks-use t("activerecord.attributes.user.quota")
        :quota_use_site_default, # i18n-tasks-use t("activerecord.attributes.user.quota_use_site_default")
        role_ids: []
      ]
    )
    # Filter out admin privilege for anyone but admins
    unless current_user&.is_administrator?
      filtered[:role_ids]&.delete_if { @available_roles.map(&:id).exclude? it.to_i }
    end
    filtered
  end

  def apply_sort_order(scope)
    case params[:order]
    when "name"
      scope.order(username: :asc)
    when "recent"
      scope.order(created_at: :desc)
    else # default to "pending"
      scope.order(approved: :asc, created_at: :desc)
    end
  end
end
