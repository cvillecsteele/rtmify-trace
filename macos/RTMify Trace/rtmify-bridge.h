#ifndef RTMIFY_BRIDGE_H
#define RTMIFY_BRIDGE_H
#include <stdint.h>

typedef struct RtmifyGraph RtmifyGraph;

#define RTMIFY_OK                  0
#define RTMIFY_ERR_FILE_NOT_FOUND  1
#define RTMIFY_ERR_INVALID_XLSX    2
#define RTMIFY_ERR_MISSING_TAB     3
#define RTMIFY_ERR_LICENSE         4
#define RTMIFY_ERR_OUTPUT          5

int32_t rtmify_load(const char* xlsx_path, RtmifyGraph** out_graph);
int32_t rtmify_generate(const RtmifyGraph* graph, const char* format,
                        const char* output_path, const char* project_name);
int32_t rtmify_gap_count(const RtmifyGraph* graph);
int32_t rtmify_warning_count(void);
const char* rtmify_last_error(void);
void rtmify_free(RtmifyGraph* graph);
int32_t rtmify_activate_license(const char* license_key);
int32_t rtmify_check_license(void);
int32_t rtmify_deactivate_license(void);

#endif
