// SOURCES: tools/sim/dump_engine_gg_model.sv src/fpga/services/dump/dump_engine.sv src/fpga/services/dump/dump_buffer.sv src/fpga/services/dump/dump_path_gen.sv src/fpga/services/dump/dump_chunk_src.sv src/fpga/services/dump/dump_checksum.sv src/fpga/services/dump/apf_file_writer.sv src/fpga/services/dump/cart_dump_gb.sv src/fpga/services/dump/cart_dump_gba.sv src/fpga/services/dump/cart_dump_gg.sv src/fpga/services/dump/cart_save_gb.sv src/fpga/services/dump/cart_save_gba.sv src/fpga/services/dump/cart_save_gba_eeprom.sv src/fpga/services/dump/gba_eeprom_io.sv src/fpga/services/dump/dump_crc32.sv src/fpga/apf/common.v
// Short APF contract check: both bridge endian modes, canonical path, separate
// numeric fields, collision-safe creation, and a complete 4096-byte payload.
module tb_dump_engine_gg_apf;
dump_engine_gg_model #(.CASE(3)) scenario();
endmodule
