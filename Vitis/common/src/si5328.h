/*
 * si5328.h — Program the 2x QSFP28 FMC's Si5328 clock generator
 *
 * Opsero 2x QSFP28 FMC reference design.
 */

#ifndef SI5328_H_
#define SI5328_H_

#include "xil_types.h"

/* GT reference clock plans (both outputs run the same frequency) */
#define SI5328_OUT_322M266   0   /* 322.265625 MHz — 100G CAUI-4  */
#define SI5328_OUT_156M25    1   /* 156.25 MHz     — 40GBASE-R4   */

int si5328_init(UINTPTR iic_base, int plan);

#endif /* SI5328_H_ */
