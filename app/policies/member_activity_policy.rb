class MemberActivityPolicy < ApplicationPolicy
  def show?
    user&.is_member? &&
      user.membership_access_active?
  end

  def destroy?
    show?
  end
end
