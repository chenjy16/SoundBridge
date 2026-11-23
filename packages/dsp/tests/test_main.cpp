/**
 * @file test_main.cpp
 * @brief Test suite entry point
 */

#include "test_utils.h"

// Declare test functions
// Preset tests
void test_preset_init_flat();
void test_preset_validate_valid();
void test_preset_validate_invalid_frequency();
void test_preset_validate_invalid_gain();
void test_preset_validate_invalid_q();

// Smoothing tests
void test_smoother_initialization();
void test_smoother_set_value_immediate();
void test_smoother_ramps_to_target();
void test_smoother_no_zipper_noise();
void test_db_to_gain_conversion();

// Biquad tests
void test_biquad_passthrough_when_flat();
void test_biquad_impulse_response_peak_filter();
void test_biquad_low_pass_attenuates_high_freq();
void test_biquad_high_pass_attenuates_low_freq();
void test_biquad_peak_filter_boosts_at_center_freq();
void test_biquad_reset_clears_state();
void test_biquad_reset_cancels_a_coefficient_transition();
void test_biquad_reset_history_keeps_the_transition_running();

// Engine tests
void test_engine_create_destroy();
void test_engine_invalid_sample_rate();
void test_engine_bypass_is_bit_perfect();
void test_engine_bypass_interleaved_is_bit_perfect();
void test_engine_apply_flat_preset();
void test_engine_process_with_flat_preset();
void test_engine_peak_filter_boosts_signal();
void test_engine_limiter_prevents_clipping();
void test_engine_update_band_gain_realtime();
void test_engine_statistics_tracking();
void test_engine_reset_clears_state();
void test_engine_band_above_nyquist_stays_finite();
void test_engine_sample_rate_change_preserves_preamp();
void test_engine_default_state_is_consistent();
void test_engine_realtime_parameter_rejects_non_finite();
void test_engine_non_finite_input_stays_finite();
void test_engine_stats_peak_reports_overrange();
void test_engine_stats_peak_is_finite_for_extreme_input();
void test_engine_stats_pre_limiter_peak_sees_overdrive();
void test_engine_stats_underrun_count_stays_reserved();
#if defined(__aarch64__) || defined(__arm64__) || defined(_M_ARM64) || \
    defined(__x86_64__) || defined(__i386__)
void test_engine_denormal_suppression_applies_to_the_calling_thread();
#endif
void test_engine_saturated_mailbox_applies_only_the_newest_update();
void test_engine_updates_from_another_thread_are_applied();
void test_engine_concurrent_preset_switching_settles_on_the_last_preset();
void test_engine_reset_survives_a_following_preset();
void test_engine_reset_does_not_cancel_a_pending_coefficient_ramp();
void test_engine_preset_snap_survives_a_coalesced_publish();
void test_engine_try_update_eq_publishes_the_whole_batch();
void test_engine_try_update_eq_is_refused_while_a_peer_holds_the_token();

// Limiter tests
void test_limiter_passes_normal_audio_unchanged();
void test_limiter_knee_is_continuous();
void test_limiter_is_monotonic();
void test_limiter_never_exceeds_threshold();
void test_limiter_non_finite_returns_silence();
void test_limiter_threshold_change_moves_knee();
void test_limiter_process_buffer_is_never_non_finite();

// Buffer arithmetic tests
void test_buffer_math_copy_bytes_does_not_wrap();
void test_buffer_math_uint32_fit_predicate();
void test_buffer_math_wrapping_expression_differs();

// Frequency response tests
void test_freq_response_flat_preset_is_transparent();
void test_freq_response_peak_filter_at_1khz();
void test_freq_response_low_shelf_boosts_bass();
void test_freq_response_high_shelf_boosts_treble();
void test_freq_response_multi_band_eq();
void test_freq_response_thd_remains_low();

// Configuration mailbox tests
void test_config_mailbox_starts_empty();
void test_config_mailbox_delivers_a_published_configuration();
void test_config_mailbox_coalesces_to_the_newest_pending_configuration();
void test_config_mailbox_survives_sustained_saturation();
void test_config_mailbox_never_tears_a_snapshot();
void test_config_mailbox_multi_producer_keeps_every_snapshot_whole();
void test_config_mailbox_indices_stay_distinct_over_time();
void test_config_mailbox_failed_attempt_leaves_the_update_pending();
void test_config_mailbox_empty_state_is_a_false_return();
void test_publisher_token_try_lock_is_bounded_and_exclusive();

// Version tests
void test_version_is_a_dotted_numeric_string();
void test_version_matches_the_repository_product_version();

int main(int argc, char** argv) {
    // Register all tests
    REGISTER_TEST(preset_init_flat);
    REGISTER_TEST(preset_validate_valid);
    REGISTER_TEST(preset_validate_invalid_frequency);
    REGISTER_TEST(preset_validate_invalid_gain);
    REGISTER_TEST(preset_validate_invalid_q);

    REGISTER_TEST(smoother_initialization);
    REGISTER_TEST(smoother_set_value_immediate);
    REGISTER_TEST(smoother_ramps_to_target);
    REGISTER_TEST(smoother_no_zipper_noise);
    REGISTER_TEST(db_to_gain_conversion);

    REGISTER_TEST(biquad_passthrough_when_flat);
    REGISTER_TEST(biquad_impulse_response_peak_filter);
    REGISTER_TEST(biquad_low_pass_attenuates_high_freq);
    REGISTER_TEST(biquad_high_pass_attenuates_low_freq);
    REGISTER_TEST(biquad_peak_filter_boosts_at_center_freq);
    REGISTER_TEST(biquad_reset_clears_state);
    REGISTER_TEST(biquad_reset_cancels_a_coefficient_transition);
    REGISTER_TEST(biquad_reset_history_keeps_the_transition_running);

    REGISTER_TEST(engine_create_destroy);
    REGISTER_TEST(engine_invalid_sample_rate);
    REGISTER_TEST(engine_bypass_is_bit_perfect);
    REGISTER_TEST(engine_bypass_interleaved_is_bit_perfect);
    REGISTER_TEST(engine_apply_flat_preset);
    REGISTER_TEST(engine_process_with_flat_preset);
    REGISTER_TEST(engine_peak_filter_boosts_signal);
    REGISTER_TEST(engine_limiter_prevents_clipping);
    REGISTER_TEST(engine_update_band_gain_realtime);
    REGISTER_TEST(engine_statistics_tracking);
    REGISTER_TEST(engine_reset_clears_state);
    REGISTER_TEST(engine_band_above_nyquist_stays_finite);
    REGISTER_TEST(engine_sample_rate_change_preserves_preamp);
    REGISTER_TEST(engine_default_state_is_consistent);
    REGISTER_TEST(engine_realtime_parameter_rejects_non_finite);
    REGISTER_TEST(engine_non_finite_input_stays_finite);
    REGISTER_TEST(engine_stats_peak_reports_overrange);
    REGISTER_TEST(engine_stats_peak_is_finite_for_extreme_input);
    REGISTER_TEST(engine_stats_pre_limiter_peak_sees_overdrive);
    REGISTER_TEST(engine_stats_underrun_count_stays_reserved);
#if defined(__aarch64__) || defined(__arm64__) || defined(_M_ARM64) || \
    defined(__x86_64__) || defined(__i386__)
    REGISTER_TEST(engine_denormal_suppression_applies_to_the_calling_thread);
#endif
    REGISTER_TEST(engine_saturated_mailbox_applies_only_the_newest_update);
    REGISTER_TEST(engine_updates_from_another_thread_are_applied);
    REGISTER_TEST(engine_concurrent_preset_switching_settles_on_the_last_preset);
    REGISTER_TEST(engine_reset_survives_a_following_preset);
    REGISTER_TEST(engine_reset_does_not_cancel_a_pending_coefficient_ramp);
    REGISTER_TEST(engine_preset_snap_survives_a_coalesced_publish);
    REGISTER_TEST(engine_try_update_eq_publishes_the_whole_batch);
    REGISTER_TEST(engine_try_update_eq_is_refused_while_a_peer_holds_the_token);

    REGISTER_TEST(limiter_passes_normal_audio_unchanged);
    REGISTER_TEST(limiter_knee_is_continuous);
    REGISTER_TEST(limiter_is_monotonic);
    REGISTER_TEST(limiter_never_exceeds_threshold);
    REGISTER_TEST(limiter_non_finite_returns_silence);
    REGISTER_TEST(limiter_threshold_change_moves_knee);
    REGISTER_TEST(limiter_process_buffer_is_never_non_finite);

    REGISTER_TEST(buffer_math_copy_bytes_does_not_wrap);
    REGISTER_TEST(buffer_math_uint32_fit_predicate);
    REGISTER_TEST(buffer_math_wrapping_expression_differs);

    REGISTER_TEST(freq_response_flat_preset_is_transparent);
    REGISTER_TEST(freq_response_peak_filter_at_1khz);
    REGISTER_TEST(freq_response_low_shelf_boosts_bass);
    REGISTER_TEST(freq_response_high_shelf_boosts_treble);
    REGISTER_TEST(freq_response_multi_band_eq);
    REGISTER_TEST(freq_response_thd_remains_low);

    REGISTER_TEST(config_mailbox_starts_empty);
    REGISTER_TEST(config_mailbox_delivers_a_published_configuration);
    REGISTER_TEST(config_mailbox_coalesces_to_the_newest_pending_configuration);
    REGISTER_TEST(config_mailbox_survives_sustained_saturation);
    REGISTER_TEST(config_mailbox_never_tears_a_snapshot);
    REGISTER_TEST(config_mailbox_multi_producer_keeps_every_snapshot_whole);
    REGISTER_TEST(config_mailbox_indices_stay_distinct_over_time);
    REGISTER_TEST(config_mailbox_failed_attempt_leaves_the_update_pending);
    REGISTER_TEST(config_mailbox_empty_state_is_a_false_return);
    REGISTER_TEST(publisher_token_try_lock_is_bounded_and_exclusive);

    REGISTER_TEST(version_is_a_dotted_numeric_string);
    REGISTER_TEST(version_matches_the_repository_product_version);

    // Run all tests
    return run_all_tests();
}
