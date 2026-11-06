# Read-only confirmation after the upload or on a retry of an immutable release tag.
module TestFlightDelivery
  APP_IDENTIFIER = "dev.dimensi.malysh"
  GROUP_NAME = "parents"
  MINIMUM_IOS = "27.0"

  class Error < StandardError; end

  def self.internal_group(app_id)
    group = Spaceship::ConnectAPI.get_beta_groups(filter: { app: app_id }).all_pages.flat_map(&:to_models)
      .find { |item| item.name == GROUP_NAME }
    unless group&.is_internal_group && group.has_access_to_all_builds
      raise Error, "TestFlight group #{GROUP_NAME} must be internal and have automatic access to new builds"
    end

    group
  end

  def self.find_build(app_id, version, build_number = nil)
    Spaceship::ConnectAPI::Build.all(
      app_id: app_id, version: version, build_number: build_number, platform: "IOS"
    ).first
  end

  def self.status(build, group)
    return "not yet visible" unless build
    if build.expired || %w[FAILED INVALID].include?(build.processing_state)
      raise Error, "Apple rejected or expired the build (#{build.processing_state})"
    end

    beta_state = build.build_beta_detail&.internal_build_state
    return [build.processing_state, beta_state].compact.join(" / ") unless
      build.processing_state == "VALID" && beta_state == "IN_BETA_TESTING"

    unless build.min_os_version == MINIMUM_IOS && build.uses_non_exempt_encryption == false
      raise Error, "Processed build does not match the expected minimum iOS or encryption declaration"
    end
    return "waiting for assignment to #{GROUP_NAME}" unless group.fetch_builds.any? { |item| item.id == build.id }

    "available"
  end

  def self.wait(app_id, group, version, build_number, timeout: 720)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    last_status = nil
    loop do
      status = status(find_build(app_id, version, build_number), group)
      yield status if status != last_status
      return if status == "available"

      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if remaining <= 0
        raise Error, "TestFlight availability not confirmed for #{version} (#{build_number}). Last status: #{status}"
      end

      last_status = status
      sleep([30, remaining].min)
    end
  end
end
