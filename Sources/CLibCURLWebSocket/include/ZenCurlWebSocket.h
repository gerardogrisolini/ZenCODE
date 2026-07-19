#ifndef ZEN_CURL_WEBSOCKET_H
#define ZEN_CURL_WEBSOCKET_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    ZEN_CURL_WS_OK = 0,
    ZEN_CURL_WS_TIMEOUT = 1,
    ZEN_CURL_WS_CLOSED = 2,
    ZEN_CURL_WS_ERROR = 3,
    ZEN_CURL_WS_UNSUPPORTED = 4
};

void *zen_curl_ws_connect(
    const char *url,
    const char *headers,
    char **error_message
);

int zen_curl_ws_send_text(
    void *connection,
    const uint8_t *bytes,
    size_t length,
    char **error_message
);

int zen_curl_ws_receive(
    void *connection,
    uint8_t **bytes,
    size_t *length,
    int *is_text,
    char **error_message
);

void zen_curl_ws_free_bytes(uint8_t *bytes);
void zen_curl_ws_free_error(char *error_message);
void zen_curl_ws_close(void *connection);

#ifdef __cplusplus
}
#endif

#endif
