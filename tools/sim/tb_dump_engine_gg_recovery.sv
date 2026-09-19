// SOURCES: tools/sim/dump_engine_gg_model.sv src/fpga/services/dump/dump_engine.sv src/fpga/services/dump/dump_buffer.sv src/fpga/services/dump/dump_path_gen.sv src/fpga/services/dump/dump_chunk_src.sv src/fpga/services/dump/dump_checksum.sv src/fpga/services/dump/apf_file_writer.sv src/fpga/services/dump/cart_dump_gb.sv src/fpga/services/dump/cart_dump_gba.sv src/fpga/services/dump/cart_dump_gg.sv src/fpga/services/dump/cart_save_gb.sv src/fpga/services/dump/cart_save_gba.sv src/fpga/services/dump/cart_save_gba_eeprom.sv src/fpga/services/dump/gba_eeprom_io.sv src/fpga/services/dump/dump_crc32.sv src/fpga/apf/common.v
// TIMEOUT: 900
// Full-image reread mismatch, APF errors, preserved partial capture, full retry.
module tb_dump_engine_gg_recovery;
dump_engine_gg_model #(.CASE(2)) scenario();
endmodule
