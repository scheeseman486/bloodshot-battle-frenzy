class_name CdTimingProfile
extends Resource
## Explicit normalized gameplay policy. Stock CD timing remains variable and is
## preserved in reference traces; this resource does not claim stock cadence.
@export var profile_id := "europe-cd-logical-six-v1"
@export var input_numerator := 53203424
@export var input_denominator := 1070460
@export var samples_per_update := 6
@export var reference_patch := "europe-cd-logical-clock-v1"
@export var source_sha256 := "e96ddb13dbe99087d1cd526bc15e022ac76c42b2efce14703fef9214ac8193a4"


func is_valid() -> bool:
	return (
		input_numerator == 53203424
		and input_denominator == 313 * 3420
		and samples_per_update in [2, 6]
		and profile_id == ("europe-cd-logical-six-v1" if samples_per_update == 6 else "europe-cd-logical-two-v1")
		and reference_patch == "europe-cd-logical-clock-v1"
		and source_sha256 == "e96ddb13dbe99087d1cd526bc15e022ac76c42b2efce14703fef9214ac8193a4"
	)
