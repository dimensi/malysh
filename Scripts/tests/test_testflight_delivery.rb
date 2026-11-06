# REL: an accepted upload must not be reported as available before Apple processes it
# and exposes the exact build to parents.
require_relative "../../fastlane/testflight_delivery"

Detail = Struct.new(:internal_build_state)
Build = Struct.new(:id, :expired, :processing_state, :build_beta_detail, :min_os_version, :uses_non_exempt_encryption)
Group = Struct.new(:fetch_builds)

def assert_equal(expected, actual)
  raise "Expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

def assert_delivery_error(expected)
  yield
  raise "Expected delivery error"
rescue TestFlightDelivery::Error => error
  raise unless error.message.include?(expected)
end

group = Group.new([])
build = Build.new("current", false, "VALID", Detail.new("READY_FOR_BETA_TESTING"), "27.0", false)
assert_equal("not yet visible", TestFlightDelivery.status(nil, group))
assert_equal("VALID / READY_FOR_BETA_TESTING", TestFlightDelivery.status(build, group))

build.build_beta_detail.internal_build_state = "IN_BETA_TESTING"
group.fetch_builds = [Build.new("previous")]
assert_equal("waiting for assignment to parents", TestFlightDelivery.status(build, group))
group.fetch_builds = [build]
assert_equal("available", TestFlightDelivery.status(build, group))

build.min_os_version = "27.1"
assert_delivery_error("minimum iOS") { TestFlightDelivery.status(build, group) }
build.processing_state = "INVALID"
assert_delivery_error("Apple rejected") { TestFlightDelivery.status(build, group) }
puts "TestFlight delivery status checks passed"
