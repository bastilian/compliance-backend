# frozen_string_literal: true

# This class is meant to contain all calls to the Remediations API.
class RemediationsAPI
  def initialize(account)
    @url = URI.parse("#{URI.parse(Settings.host_inventory_url)}"\
                     "#{ENV['PATH_PREFIX']}/remediations/v1/resolutions")
    @b64_identity = Base64.strict_encode64(account.fake_identity_header.to_json)
  end

  def import_remediations
    Rule.find_in_batches(batch_size: 100).each do |rules|
      response = Platform.connection.post(@url) do |req|
        req.headers['X_RH_IDENTITY'] = @b64_identity
        req.headers['Content-Type'] = 'application/json'
        req.body = { 'issues': build_issues_list(rules) }.to_json
      end
      update_rules(remediations_available(response))
    end
  rescue Faraday::ClientError => e
    Rails.logger.info("#{e.message} #{e.response}")
  end

  private

  def remove_ref_id_prefix(ref_id)
    short_ref_id = ref_id.downcase.split(
      'xccdf_org.ssgproject.content_profile_'
    )[1]
    short_ref_id || ref_id
  end

  def build_issues_list(rules)
    profile_rules = profile_for_rules(rules)

    rules.map do |rule|
      "ssg:rhel7|#{remove_ref_id_prefix(profile_rules[rule.id])}"\
        "|#{rule.ref_id}"
    end
  end

  def profile_for_rules(rules)
    profile_rules = ProfileRule.where(rule_id: rules.pluck(:id))
                               .pluck(:rule_id, :profile_id).to_h
    profile_ref_ids = Profile.where(id: profile_rules.values.uniq)
                             .pluck(:id, :ref_id).to_h
    profile_rules.transform_values! { |profile_id| profile_ref_ids[profile_id] }
  end

  def remediations_available(response)
    JSON.parse(response.body).each_with_object(
      'true' => [], 'false' => []
    ) do |(remediation_id, value), remediation_available|
      rule_ref_id = remediation_id.split('|')[2]
      Rails.logger.info("Updating rule #{rule_ref_id} "\
                        "remediation_available: #{value.present?}")
      remediation_available[value.present?.to_s] << rule_ref_id
    end
  end

  def update_rules(remediations)
    remediations.each do |available, rule_ref_ids|
      # rubocop:disable Rails/SkipsModelValidations
      Rule.where(ref_id: rule_ref_ids).update_all(
        remediation_available: ActiveModel::Type::Boolean.new.cast(available)
      )
      # rubocop:enable Rails/SkipsModelValidations
    end
  end
end