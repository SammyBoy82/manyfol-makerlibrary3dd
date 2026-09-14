class Settings::InvitationsController < ApplicationController
  before_action :require_administrator!
  before_action :get_invitation, only: [:resend, :revoke]

  ALLOWED_ROLES = %w[
    member
    contributor
    moderator
    administrator
  ].freeze

  def index
    skip_policy_scope
    skip_authorization

    invitations =
      User
        .where.not(invitation_created_at: nil)
        .includes(:membership_plan, :roles)

    @pending_invitations =
      invitations
        .where(invitation_accepted_at: nil)
        .order(invitation_sent_at: :desc)
        .limit(100)

    @accepted_invitations =
      invitations
        .where.not(invitation_accepted_at: nil)
        .order(invitation_accepted_at: :desc)
        .limit(25)

    @plans = MembershipPlan.enabled.order(:name)
    @email_configured = SiteSettings.email_configured?

    @pending_count = @pending_invitations.count
    @expired_count = @pending_invitations.count do |invitation|
      invitation.invitation_due_at.present? &&
        invitation.invitation_due_at <= Time.current
    end
    @accepted_count =
      invitations
        .where.not(invitation_accepted_at: nil)
        .count

    render layout: "settings"
  end

  def create
    skip_authorization

    unless SiteSettings.email_configured?
      redirect_to(
        settings_invitations_path,
        alert: "Email delivery must be configured before sending invitations."
      )
      return
    end

    email = params[:email].to_s.strip.downcase
    role = params[:membership_role].to_s
    role = "member" if role.blank?

    unless email.match?(URI::MailTo::EMAIL_REGEXP)
      redirect_to(
        settings_invitations_path,
        alert: "Enter a valid email address."
      )
      return
    end

    unless ALLOWED_ROLES.include?(role)
      redirect_to(
        settings_invitations_path,
        alert: "Invalid membership role."
      )
      return
    end

    if User.where("LOWER(email) = ?", email).exists?
      redirect_to(
        settings_invitations_path,
        alert: "An account or pending invitation already exists for this email address."
      )
      return
    end

    plan =
      if params[:membership_plan_id].present?
        MembershipPlan.enabled.find(params[:membership_plan_id])
      end

    expires_at =
      if params[:membership_expires_at].present?
        Time.zone.parse(params[:membership_expires_at].to_s)
      end

    invitation =
      User.invite!(
        email: email,
        approved: true,
        membership_status: "active",
        membership_plan: plan,
        membership_started_at: nil,
        membership_expires_at: expires_at,
        membership_admin_notes: params[:membership_admin_notes].to_s.strip
      )

    if invitation.errors.any?
      redirect_to(
        settings_invitations_path,
        alert: invitation.errors.full_messages.join(", ")
      )
      return
    end

    assign_role(invitation, role)

    AdminAudit.record(
      actor: current_user,
      action: "membership_invitation_created",
      target: invitation,
      request: request,
      after_data: invitation_audit_snapshot(invitation),
      context: {
        delivery: "email",
        expires_at: invitation.invitation_due_at&.iso8601
      }
    )

    redirect_to(
      settings_invitations_path,
      notice: "Invitation sent to #{email}."
    )
  rescue ArgumentError
    redirect_to(
      settings_invitations_path,
      alert: "The membership expiry date is invalid."
    )
  end

  def resend
    skip_authorization

    unless SiteSettings.email_configured?
      redirect_to(
        settings_invitations_path,
        alert: "Email delivery must be configured before resending invitations."
      )
      return
    end

    @invitation.invite!

    if @invitation.errors.any?
      redirect_to(
        settings_invitations_path,
        alert: @invitation.errors.full_messages.join(", ")
      )
      return
    end

    AdminAudit.record(
      actor: current_user,
      action: "membership_invitation_resent",
      target: @invitation,
      request: request,
      after_data: invitation_audit_snapshot(@invitation),
      context: {
        expires_at: @invitation.invitation_due_at&.iso8601
      }
    )

    redirect_to(
      settings_invitations_path,
      notice: "Invitation resent to #{@invitation.email}."
    )
  end

  def revoke
    skip_authorization

    snapshot = invitation_audit_snapshot(@invitation)
    email = @invitation.email

    AdminAudit.record(
      actor: current_user,
      action: "membership_invitation_revoked",
      target: @invitation,
      request: request,
      before_data: snapshot
    )

    @invitation.destroy!

    redirect_to(
      settings_invitations_path,
      notice: "Invitation revoked for #{email}."
    )
  end

  private

  def require_administrator!
    raise Pundit::NotAuthorizedError unless current_user&.is_administrator?
  end

  def get_invitation
    @invitation =
      User
        .where.not(invitation_created_at: nil)
        .where(invitation_accepted_at: nil)
        .find(params[:id])
  end

  def assign_role(user, role)
    user.add_role(:member)

    %i[
      contributor
      moderator
      administrator
    ].each do |managed_role|
      user.remove_role(managed_role)
    end

    user.add_role(role.to_sym) unless role == "member"
  end

  def invitation_audit_snapshot(user)
    {
      email: user.email,
      username: user.username,
      roles: user.roles.pluck(:name).sort,
      membership_plan_id: user.membership_plan_id,
      membership_plan: user.membership_plan&.name,
      membership_status: user.membership_status,
      membership_expires_at: user.membership_expires_at&.iso8601,
      invitation_sent_at: user.invitation_sent_at&.iso8601,
      invitation_accepted_at: user.invitation_accepted_at&.iso8601
    }
  end
end
