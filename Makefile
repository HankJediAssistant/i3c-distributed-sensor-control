RTL_SRCS := \
	rtl/i3c_bus_engine.v \
	rtl/i3c_ctrl_ccc.v \
	rtl/i3c_ctrl_daa.v \
	rtl/i3c_ctrl_direct_ccc.v \
	rtl/i3c_ctrl_entdaa.v \
	rtl/i3c_ctrl_inventory.v \
	rtl/i3c_known_target_hub.v \
	rtl/i3c_ctrl_policy.v \
	rtl/i3c_ctrl_scheduler.v \
	rtl/i3c_ctrl_top.v \
	rtl/i3c_ctrl_txn_layer.v \
	rtl/i3c_sdr_controller.v \
	rtl/i3c_target_ccc.v \
	rtl/i3c_target_daa.v \
	rtl/i3c_target_top.v \
	rtl/i3c_target_transport.v \
	rtl/uart_dual_target_lab_cmd_handler.v

FPGA_TEST_RTL_SRCS := \
	$(RTL_SRCS) \
	rtl/fpga_test/i3c_demo_rate_tick.v \
	rtl/fpga_test/i3c_dual_target_lab_controller.v \
	rtl/fpga_test/i3c_sensor_frame_gen.v \
	rtl/fpga_test/i3c_sensor_gpio_target_demo.v \
	rtl/fpga_test/i3c_sensor_target_demo.v \
	rtl/fpga_test/i3c_sensor_controller_demo.v

FPGA_TEST_BOARD_SRCS := \
	$(FPGA_TEST_RTL_SRCS) \
	rtl/fpga_test/spartan7_i3c_controller_demo_top.v \
	rtl/fpga_test/spartan7_i3c_dual_target_lab_top.v \
	rtl/fpga_test/spartan7_i3c_target_demo_top.v

COMMON_TB_SRCS := \
	tb/i3c_target_model.v \
	tb/i3c_direct_ccc_responder.v

SIM_RW_OUT := simv_rw
SIM_NACK_OUT := simv_nack
SIM_TARGET_OUT := simv_target
SIM_DAA_OUT := simv_daa
SIM_CCC_OUT := simv_ccc
SIM_DIRECT_CCC_WRITE_OUT := simv_direct_ccc_write
SIM_DIRECT_CCC_READ_OUT := simv_direct_ccc_read
SIM_SETDASA_OUT := simv_setdasa
SIM_GETPID_OUT := simv_getpid
SIM_GETBCRDCR_OUT := simv_getbcrdcr
SIM_GETSTATUS_OUT := simv_getstatus
SIM_ENTDAA_OUT := simv_entdaa
SIM_ENTDAA_MULTI_OUT := simv_entdaa_multi
SIM_ENTDAA_STRESS_OUT := simv_entdaa_stress
SIM_SCHEDULER_OUT := simv_scheduler
SIM_CTRL_TOP_SERVICE_OUT := simv_ctrl_top_service
SIM_FIVE_TARGET_SAMPLING_OUT := simv_five_target_sampling_system
SIM_FPGA_TEST_SYSTEM_OUT := simv_fpga_test_system
SIM_EVENT_POLICY_CCC_OUT := simv_event_policy_ccc
SIM_RESET_STATUS_POLICY_OUT := simv_reset_status_policy
SIM_RECOVERY_SEQUENCE_OUT := simv_recovery_sequence
SIM_WAVE1_CCC_OUT := simv_wave1_ccc
SIM_WAVE3_ACTIVITY_GROUP_OUT := simv_wave3_activity_group
SIM_KNOWN_TARGET_HUB_OUT := simv_known_target_hub
SIM_DUAL_TARGET_LAB_CONTROLLER_OUT := simv_dual_target_lab_controller
SIM_DUAL_TARGET_LAB_CONTROLLER_ENTDAA_OUT := simv_dual_target_lab_controller_entdaa
SIM_EXTERNAL_BUS_PUSHPULL_OUT := simv_external_bus_pushpull
SIM_EXTERNAL_BUS_PUSHPULL_8M_OUT := simv_external_bus_pushpull_8m
SIM_EXTERNAL_BUS_PUSHPULL_12M5_OUT := simv_external_bus_pushpull_12m5

.PHONY: sim sim-rw sim-nack sim-target sim-daa sim-ccc sim-direct-ccc-write sim-direct-ccc-read sim-setdasa sim-getpid sim-getbcrdcr sim-getstatus sim-entdaa sim-entdaa-multi sim-entdaa-stress sim-scheduler sim-ctrl-top-service sim-five-target-sampling-system sim-fpga-test-system sim-event-policy-ccc sim-reset-status-policy sim-recovery-sequence sim-wave1-ccc sim-wave3-activity-group sim-known-target-hub sim-dual-target-lab-controller sim-dual-target-lab-controller-entdaa test clean

sim: test

test: sim-rw sim-nack sim-target sim-daa sim-ccc sim-direct-ccc-write sim-direct-ccc-read sim-setdasa sim-getpid sim-getbcrdcr sim-getstatus sim-entdaa sim-entdaa-multi sim-entdaa-stress sim-scheduler sim-ctrl-top-service sim-five-target-sampling-system sim-fpga-test-system sim-event-policy-ccc sim-reset-status-policy sim-recovery-sequence sim-wave1-ccc sim-wave3-activity-group sim-known-target-hub sim-dual-target-lab-controller sim-dual-target-lab-controller-entdaa

sim-rw:
	iverilog -g2012 -Wall -o $(SIM_RW_OUT) $(RTL_SRCS) $(COMMON_TB_SRCS) tb/tb_i3c_sdr_controller.v
	vvp $(SIM_RW_OUT)

sim-nack:
	iverilog -g2012 -Wall -o $(SIM_NACK_OUT) $(RTL_SRCS) $(COMMON_TB_SRCS) tb/tb_i3c_sdr_nack.v
	vvp $(SIM_NACK_OUT)

sim-target:
	iverilog -g2012 -Wall -o $(SIM_TARGET_OUT) $(RTL_SRCS) tb/tb_i3c_target_transport.v
	vvp $(SIM_TARGET_OUT)

sim-daa:
	iverilog -g2012 -Wall -o $(SIM_DAA_OUT) $(RTL_SRCS) tb/tb_i3c_daa_state.v
	vvp $(SIM_DAA_OUT)

sim-ccc:
	iverilog -g2012 -Wall -o $(SIM_CCC_OUT) $(RTL_SRCS) tb/tb_i3c_broadcast_ccc.v
	vvp $(SIM_CCC_OUT)

sim-direct-ccc-write:
	iverilog -g2012 -Wall -o $(SIM_DIRECT_CCC_WRITE_OUT) $(RTL_SRCS) tb/i3c_direct_ccc_responder.v tb/tb_i3c_direct_ccc_write.v
	vvp $(SIM_DIRECT_CCC_WRITE_OUT)

sim-direct-ccc-read:
	iverilog -g2012 -Wall -o $(SIM_DIRECT_CCC_READ_OUT) $(RTL_SRCS) tb/i3c_direct_ccc_responder.v tb/tb_i3c_direct_ccc_read.v
	vvp $(SIM_DIRECT_CCC_READ_OUT)

sim-setdasa:
	iverilog -g2012 -Wall -o $(SIM_SETDASA_OUT) $(RTL_SRCS) tb/tb_i3c_setdasa.v
	vvp $(SIM_SETDASA_OUT)

sim-getpid:
	iverilog -g2012 -Wall -o $(SIM_GETPID_OUT) $(RTL_SRCS) tb/tb_i3c_getpid.v
	vvp $(SIM_GETPID_OUT)

sim-getbcrdcr:
	iverilog -g2012 -Wall -o $(SIM_GETBCRDCR_OUT) $(RTL_SRCS) tb/tb_i3c_getbcrdcr.v
	vvp $(SIM_GETBCRDCR_OUT)

sim-getstatus:
	iverilog -g2012 -Wall -o $(SIM_GETSTATUS_OUT) $(RTL_SRCS) tb/tb_i3c_getstatus.v
	vvp $(SIM_GETSTATUS_OUT)

sim-entdaa:
	iverilog -g2012 -Wall -o $(SIM_ENTDAA_OUT) $(RTL_SRCS) tb/tb_i3c_entdaa.v
	vvp $(SIM_ENTDAA_OUT)

sim-entdaa-multi:
	iverilog -g2012 -Wall -o $(SIM_ENTDAA_MULTI_OUT) $(RTL_SRCS) tb/tb_i3c_entdaa_multi.v
	vvp $(SIM_ENTDAA_MULTI_OUT)

sim-entdaa-stress:
	iverilog -g2012 -Wall -o $(SIM_ENTDAA_STRESS_OUT) $(RTL_SRCS) tb/tb_i3c_entdaa_stress.v
	vvp $(SIM_ENTDAA_STRESS_OUT)

sim-scheduler:
	iverilog -g2012 -Wall -o $(SIM_SCHEDULER_OUT) $(RTL_SRCS) tb/tb_i3c_scheduler.v
	vvp $(SIM_SCHEDULER_OUT)

sim-ctrl-top-service:
	iverilog -g2012 -Wall -o $(SIM_CTRL_TOP_SERVICE_OUT) $(RTL_SRCS) tb/tb_i3c_ctrl_top_service.v
	vvp $(SIM_CTRL_TOP_SERVICE_OUT)

sim-five-target-sampling-system:
	iverilog -g2012 -Wall -o $(SIM_FIVE_TARGET_SAMPLING_OUT) $(RTL_SRCS) tb/tb_i3c_five_target_sampling_system.v
	vvp $(SIM_FIVE_TARGET_SAMPLING_OUT)

sim-fpga-test-system:
	iverilog -g2012 -Wall -o $(SIM_FPGA_TEST_SYSTEM_OUT) $(FPGA_TEST_RTL_SRCS) tb/tb_i3c_fpga_test_system.v
	vvp $(SIM_FPGA_TEST_SYSTEM_OUT)

sim-event-policy-ccc:
	iverilog -g2012 -Wall -o $(SIM_EVENT_POLICY_CCC_OUT) $(RTL_SRCS) tb/tb_i3c_event_policy_ccc.v
	vvp $(SIM_EVENT_POLICY_CCC_OUT)

sim-reset-status-policy:
	iverilog -g2012 -Wall -o $(SIM_RESET_STATUS_POLICY_OUT) $(RTL_SRCS) tb/tb_i3c_reset_status_policy.v
	vvp $(SIM_RESET_STATUS_POLICY_OUT)

sim-recovery-sequence:
	iverilog -g2012 -Wall -o $(SIM_RECOVERY_SEQUENCE_OUT) $(RTL_SRCS) tb/tb_i3c_recovery_sequence.v
	vvp $(SIM_RECOVERY_SEQUENCE_OUT)

sim-wave1-ccc:
	iverilog -g2012 -Wall -o $(SIM_WAVE1_CCC_OUT) $(RTL_SRCS) tb/tb_i3c_wave1_ccc.v
	vvp $(SIM_WAVE1_CCC_OUT)

sim-wave3-activity-group:
	iverilog -g2012 -Wall -o $(SIM_WAVE3_ACTIVITY_GROUP_OUT) $(RTL_SRCS) tb/tb_i3c_wave3_activity_group.v
	vvp $(SIM_WAVE3_ACTIVITY_GROUP_OUT)

sim-known-target-hub:
	iverilog -g2012 -Wall -o $(SIM_KNOWN_TARGET_HUB_OUT) $(RTL_SRCS) tb/tb_i3c_known_target_hub.v
	vvp $(SIM_KNOWN_TARGET_HUB_OUT)

sim-dual-target-lab-controller:
	iverilog -g2012 -Wall -o $(SIM_DUAL_TARGET_LAB_CONTROLLER_OUT) $(FPGA_TEST_RTL_SRCS) tb/tb_i3c_dual_target_lab_controller.v
	vvp $(SIM_DUAL_TARGET_LAB_CONTROLLER_OUT)

sim-dual-target-lab-controller-entdaa:
	iverilog -g2012 -Wall -Ptb_i3c_dual_target_lab_controller.USE_ENTDAA=1 \
		-o $(SIM_DUAL_TARGET_LAB_CONTROLLER_ENTDAA_OUT) \
		$(FPGA_TEST_RTL_SRCS) tb/tb_i3c_dual_target_lab_controller.v
	vvp $(SIM_DUAL_TARGET_LAB_CONTROLLER_ENTDAA_OUT)

# Phase 3-B' push-pull bus regression. Contention-aware bus model asserts
# that targets actively drive SDA HIGH (not via pullup) during SDR read
# data phases, and that no contention occurs across T-bit handoffs.
sim-external-bus-pushpull:
	iverilog -g2012 -Wall \
		-o $(SIM_EXTERNAL_BUS_PUSHPULL_OUT) \
		$(FPGA_TEST_RTL_SRCS) tb/tb_i3c_external_bus_pushpull.v
	vvp $(SIM_EXTERNAL_BUS_PUSHPULL_OUT)

sim-external-bus-pushpull-entdaa:
	iverilog -g2012 -Wall -Ptb_i3c_external_bus_pushpull.USE_ENTDAA=1 \
		-o $(SIM_EXTERNAL_BUS_PUSHPULL_OUT)_entdaa \
		$(FPGA_TEST_RTL_SRCS) tb/tb_i3c_external_bus_pushpull.v
	vvp $(SIM_EXTERNAL_BUS_PUSHPULL_OUT)_entdaa

sim-external-bus-pushpull-8m:
	iverilog -g2012 -Wall -Ptb_i3c_external_bus_pushpull.I3C_SDR_HZ=8000000 \
		-o $(SIM_EXTERNAL_BUS_PUSHPULL_8M_OUT) \
		$(FPGA_TEST_RTL_SRCS) tb/tb_i3c_external_bus_pushpull.v
	vvp $(SIM_EXTERNAL_BUS_PUSHPULL_8M_OUT)

sim-external-bus-pushpull-12m5:
	iverilog -g2012 -Wall -Ptb_i3c_external_bus_pushpull.I3C_SDR_HZ=12500000 \
		-o $(SIM_EXTERNAL_BUS_PUSHPULL_12M5_OUT) \
		$(FPGA_TEST_RTL_SRCS) tb/tb_i3c_external_bus_pushpull.v
	vvp $(SIM_EXTERNAL_BUS_PUSHPULL_12M5_OUT)

clean:
	rm -f $(SIM_RW_OUT) $(SIM_NACK_OUT) $(SIM_TARGET_OUT) $(SIM_DAA_OUT) $(SIM_CCC_OUT) $(SIM_DIRECT_CCC_WRITE_OUT) $(SIM_DIRECT_CCC_READ_OUT) $(SIM_SETDASA_OUT) $(SIM_GETPID_OUT) $(SIM_GETBCRDCR_OUT) $(SIM_GETSTATUS_OUT) $(SIM_ENTDAA_OUT) $(SIM_ENTDAA_MULTI_OUT) $(SIM_ENTDAA_STRESS_OUT) $(SIM_SCHEDULER_OUT) $(SIM_CTRL_TOP_SERVICE_OUT) $(SIM_FIVE_TARGET_SAMPLING_OUT) $(SIM_FPGA_TEST_SYSTEM_OUT) $(SIM_EVENT_POLICY_CCC_OUT) $(SIM_RESET_STATUS_POLICY_OUT) $(SIM_RECOVERY_SEQUENCE_OUT) $(SIM_WAVE1_CCC_OUT) $(SIM_WAVE3_ACTIVITY_GROUP_OUT) $(SIM_KNOWN_TARGET_HUB_OUT) $(SIM_DUAL_TARGET_LAB_CONTROLLER_OUT) $(SIM_DUAL_TARGET_LAB_CONTROLLER_ENTDAA_OUT) $(SIM_EXTERNAL_BUS_PUSHPULL_OUT) $(SIM_EXTERNAL_BUS_PUSHPULL_8M_OUT) $(SIM_EXTERNAL_BUS_PUSHPULL_12M5_OUT) tb_i3c_sdr_controller.vcd tb_i3c_sdr_nack.vcd tb_i3c_target_transport.vcd tb_i3c_broadcast_ccc.vcd tb_i3c_direct_ccc_write.vcd tb_i3c_direct_ccc_read.vcd tb_i3c_setdasa.vcd tb_i3c_getpid.vcd tb_i3c_getbcrdcr.vcd tb_i3c_getstatus.vcd tb_i3c_entdaa.vcd tb_i3c_entdaa_multi.vcd tb_i3c_entdaa_stress.vcd tb_i3c_scheduler.vcd tb_i3c_ctrl_top_service.vcd tb_i3c_five_target_sampling_system.vcd tb_i3c_fpga_test_system.vcd tb_i3c_event_policy_ccc.vcd tb_i3c_reset_status_policy.vcd tb_i3c_recovery_sequence.vcd tb_i3c_wave1_ccc.vcd tb_i3c_wave3_activity_group.vcd tb_i3c_known_target_hub.vcd tb_i3c_dual_target_lab_controller.vcd tb_i3c_external_bus_pushpull.vcd
