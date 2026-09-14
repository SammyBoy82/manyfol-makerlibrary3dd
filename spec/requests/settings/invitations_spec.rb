require "rails_helper"

RSpec.describe "/settings/invitations", :after_first_run, :multiuser do
  before do
    allow(SiteSettings)
      .to receive(:email_configured?)
      .and_return(true)
  end

  describe "GET /settings/invitations", :as_administrator do
    it "renders the invitation dashboard" do
      get "/settings/invitations"

      expect(response).to be_successful
      expect(response.body).to include("Membership Invitations")
    end
  end

  describe "POST /settings/invitations", :as_administrator do
    let!(:plan) do
      MembershipPlan.create!(
        name: "Invitation Test Plan",
        description: "Request spec",
        billing_interval: "month",
        active: true,
        all_libraries: true
      )
    end

    it "creates a pending invitation with its assigned plan and role" do
      expect {
        post "/settings/invitations",
          params: {
            email: "invited-member@example.com",
            membership_role: "contributor",
            membership_plan_id: plan.id,
            membership_admin_notes: "Created by request spec"
          }
      }.to change(User.where.not(invitation_token: nil), :count).by(1)

      invitation = User.find_by!(email: "invited-member@example.com")

      expect(invitation).to have_role(:member)
      expect(invitation).to have_role(:contributor)
      expect(invitation.membership_plan).to eq(plan)
      expect(invitation.approved?).to be(true)
      expect(invitation.invitation_sent_at).to be_present
      expect(response).to redirect_to(settings_invitations_path)
    end

    it "does not create a duplicate account or invitation" do
      create(:user, email: "existing@example.com")

      expect {
        post "/settings/invitations",
          params: {
            email: "EXISTING@example.com",
            membership_role: "member"
          }
      }.not_to change(User, :count)

      expect(response).to redirect_to(settings_invitations_path)
    end

    it "rejects unsupported roles" do
      expect {
        post "/settings/invitations",
          params: {
            email: "invalid-role@example.com",
            membership_role: "owner"
          }
      }.not_to change(User, :count)

      expect(response).to redirect_to(settings_invitations_path)
    end
  end

  describe "POST /settings/invitations/:id/resend", :as_administrator do
    it "rotates and resends a pending invitation" do
      invitation =
        User.invite!(
          email: "resend@example.com",
          approved: true,
          membership_status: "active"
        )

      original_token = invitation.invitation_token

      post "/settings/invitations/#{invitation.id}/resend"

      expect(response).to redirect_to(settings_invitations_path)
      expect(invitation.reload.invitation_token).not_to eq(original_token)
    end
  end

  describe "DELETE /settings/invitations/:id/revoke", :as_administrator do
    it "removes only the pending invited account" do
      invitation =
        User.invite!(
          email: "revoke@example.com",
          approved: true,
          membership_status: "active"
        )

      expect {
        delete "/settings/invitations/#{invitation.id}/revoke"
      }.to change(User, :count).by(-1)

      expect(response).to redirect_to(settings_invitations_path)
    end
  end
end
