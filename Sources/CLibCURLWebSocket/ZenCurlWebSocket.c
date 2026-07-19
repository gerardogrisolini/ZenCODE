#include "ZenCurlWebSocket.h"

#include <curl/curl.h>
#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>

#define ZEN_CURL_WS_MAX_MESSAGE_SIZE (16u * 1024u * 1024u)
#define ZEN_CURL_WS_IO_TIMEOUT_MS 1000

struct zen_curl_ws_connection {
    CURL *easy;
    struct curl_slist *headers;
    char error_buffer[CURL_ERROR_SIZE];
};

static void zen_curl_ws_set_error(char **output, const char *message) {
    if (output == NULL) {
        return;
    }
    *output = strdup(message != NULL && message[0] != '\0'
        ? message
        : "Unknown libcurl WebSocket error");
}

static void zen_curl_ws_set_curl_error(
    struct zen_curl_ws_connection *connection,
    CURLcode code,
    char **output
) {
    const char *message = connection != NULL
        && connection->error_buffer[0] != '\0'
        ? connection->error_buffer
        : curl_easy_strerror(code);
    zen_curl_ws_set_error(output, message);
}

static int zen_curl_ws_wait(
    struct zen_curl_ws_connection *connection,
    short events
) {
    curl_socket_t socket = CURL_SOCKET_BAD;
    CURLcode result = curl_easy_getinfo(
        connection->easy,
        CURLINFO_ACTIVESOCKET,
        &socket
    );
    if (result != CURLE_OK || socket == CURL_SOCKET_BAD) {
        return -1;
    }

    struct pollfd descriptor;
    descriptor.fd = socket;
    descriptor.events = events;
    descriptor.revents = 0;
    do {
        result = (CURLcode)poll(&descriptor, 1, ZEN_CURL_WS_IO_TIMEOUT_MS);
    } while ((int)result < 0 && errno == EINTR);
    return (int)result;
}

static int zen_curl_ws_append(
    uint8_t **buffer,
    size_t *length,
    const uint8_t *chunk,
    size_t chunk_length
) {
    if (chunk_length > ZEN_CURL_WS_MAX_MESSAGE_SIZE - *length) {
        return 0;
    }
    uint8_t *expanded = realloc(*buffer, *length + chunk_length);
    if (expanded == NULL && chunk_length > 0) {
        return 0;
    }
    if (chunk_length > 0) {
        memcpy(expanded + *length, chunk, chunk_length);
    }
    *buffer = expanded;
    *length += chunk_length;
    return 1;
}

void *zen_curl_ws_connect(
    const char *url,
    const char *headers,
    char **error_message
) {
    if (error_message != NULL) {
        *error_message = NULL;
    }
#if LIBCURL_VERSION_NUM < 0x075600
    (void)url;
    (void)headers;
    zen_curl_ws_set_error(
        error_message,
        "ChatGPT WebSocket requires libcurl 7.86.0 or newer"
    );
    return NULL;
#else
    CURLcode global_result = curl_global_init(CURL_GLOBAL_DEFAULT);
    if (global_result != CURLE_OK) {
        zen_curl_ws_set_error(error_message, curl_easy_strerror(global_result));
        return NULL;
    }
    struct zen_curl_ws_connection *connection = calloc(1, sizeof(*connection));
    if (connection == NULL) {
        zen_curl_ws_set_error(error_message, "Unable to allocate WebSocket connection");
        return NULL;
    }

    connection->easy = curl_easy_init();
    if (connection->easy == NULL) {
        zen_curl_ws_set_error(error_message, "Unable to initialize libcurl");
        free(connection);
        return NULL;
    }

    if (headers != NULL && headers[0] != '\0') {
        char *copy = strdup(headers);
        if (copy == NULL) {
            zen_curl_ws_set_error(error_message, "Unable to allocate WebSocket headers");
            zen_curl_ws_close(connection);
            return NULL;
        }
        char *save_pointer = NULL;
        char *line = strtok_r(copy, "\n", &save_pointer);
        while (line != NULL) {
            if (line[0] != '\0') {
                struct curl_slist *updated = curl_slist_append(connection->headers, line);
                if (updated == NULL) {
                    free(copy);
                    zen_curl_ws_set_error(error_message, "Unable to allocate WebSocket headers");
                    zen_curl_ws_close(connection);
                    return NULL;
                }
                connection->headers = updated;
            }
            line = strtok_r(NULL, "\n", &save_pointer);
        }
        free(copy);
    }

    connection->error_buffer[0] = '\0';
    curl_easy_setopt(connection->easy, CURLOPT_ERRORBUFFER, connection->error_buffer);
    curl_easy_setopt(connection->easy, CURLOPT_URL, url);
    curl_easy_setopt(connection->easy, CURLOPT_HTTPHEADER, connection->headers);
    curl_easy_setopt(connection->easy, CURLOPT_CONNECT_ONLY, 2L);
    curl_easy_setopt(connection->easy, CURLOPT_CONNECTTIMEOUT, 30L);
    curl_easy_setopt(connection->easy, CURLOPT_TIMEOUT, 600L);
    curl_easy_setopt(connection->easy, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(connection->easy, CURLOPT_FAILONERROR, 1L);
    curl_easy_setopt(connection->easy, CURLOPT_USERAGENT, "ZenCODE");

    CURLcode result = curl_easy_perform(connection->easy);
    if (result != CURLE_OK) {
        zen_curl_ws_set_curl_error(connection, result, error_message);
        zen_curl_ws_close(connection);
        return NULL;
    }
    return connection;
#endif
}

int zen_curl_ws_send_text(
    void *opaque_connection,
    const uint8_t *bytes,
    size_t length,
    char **error_message
) {
#if LIBCURL_VERSION_NUM < 0x075600
    (void)opaque_connection;
    (void)bytes;
    (void)length;
    zen_curl_ws_set_error(error_message, "WebSocket is unsupported by this libcurl");
    return ZEN_CURL_WS_UNSUPPORTED;
#else
    struct zen_curl_ws_connection *connection = opaque_connection;
    size_t offset = 0;
    if (error_message != NULL) {
        *error_message = NULL;
    }
    while (offset < length) {
        size_t sent = 0;
        CURLcode result = curl_ws_send(
            connection->easy,
            bytes + offset,
            length - offset,
            &sent,
            0,
            CURLWS_TEXT
        );
        offset += sent;
        if (result == CURLE_OK) {
            continue;
        }
        if (result == CURLE_AGAIN) {
            if (zen_curl_ws_wait(connection, POLLOUT) >= 0) {
                continue;
            }
        }
        zen_curl_ws_set_curl_error(connection, result, error_message);
        return ZEN_CURL_WS_ERROR;
    }
    return ZEN_CURL_WS_OK;
#endif
}

int zen_curl_ws_receive(
    void *opaque_connection,
    uint8_t **bytes,
    size_t *length,
    int *is_text,
    char **error_message
) {
#if LIBCURL_VERSION_NUM < 0x075600
    (void)opaque_connection;
    (void)bytes;
    (void)length;
    (void)is_text;
    zen_curl_ws_set_error(error_message, "WebSocket is unsupported by this libcurl");
    return ZEN_CURL_WS_UNSUPPORTED;
#else
    struct zen_curl_ws_connection *connection = opaque_connection;
    uint8_t *message = NULL;
    size_t message_length = 0;
    int message_is_text = 0;
    int assembling_message = 0;
    uint8_t chunk[64 * 1024];

    *bytes = NULL;
    *length = 0;
    *is_text = 0;
    if (error_message != NULL) {
        *error_message = NULL;
    }

    for (;;) {
        size_t received = 0;
        const struct curl_ws_frame *metadata = NULL;
        CURLcode result = curl_ws_recv(
            connection->easy,
            chunk,
            sizeof(chunk),
            &received,
            &metadata
        );

        if (result == CURLE_AGAIN) {
            int ready = zen_curl_ws_wait(connection, POLLIN);
            if (ready == 0 && !assembling_message) {
                free(message);
                return ZEN_CURL_WS_TIMEOUT;
            }
            if (ready >= 0) {
                continue;
            }
        }
        if (result == CURLE_GOT_NOTHING) {
            free(message);
            return ZEN_CURL_WS_CLOSED;
        }
        if (result != CURLE_OK || metadata == NULL) {
            zen_curl_ws_set_curl_error(connection, result, error_message);
            free(message);
            return ZEN_CURL_WS_ERROR;
        }

        if ((metadata->flags & CURLWS_CLOSE) != 0) {
            free(message);
            return ZEN_CURL_WS_CLOSED;
        }
        if ((metadata->flags & (CURLWS_PING | CURLWS_PONG)) != 0) {
            continue;
        }
        if ((metadata->flags & (CURLWS_TEXT | CURLWS_BINARY)) == 0) {
            continue;
        }

        assembling_message = 1;
        if (message_length == 0) {
            message_is_text = (metadata->flags & CURLWS_TEXT) != 0;
        }
        if (!zen_curl_ws_append(
                &message,
                &message_length,
                chunk,
                received
            )) {
            zen_curl_ws_set_error(error_message, "WebSocket message exceeds 16 MiB");
            free(message);
            return ZEN_CURL_WS_ERROR;
        }

        if (metadata->bytesleft == 0 && (metadata->flags & CURLWS_CONT) == 0) {
            *bytes = message;
            *length = message_length;
            *is_text = message_is_text;
            return ZEN_CURL_WS_OK;
        }
    }
#endif
}

void zen_curl_ws_free_bytes(uint8_t *bytes) {
    free(bytes);
}

void zen_curl_ws_free_error(char *error_message) {
    free(error_message);
}

void zen_curl_ws_close(void *opaque_connection) {
    struct zen_curl_ws_connection *connection = opaque_connection;
    if (connection == NULL) {
        return;
    }
    if (connection->easy != NULL) {
        curl_easy_cleanup(connection->easy);
    }
    if (connection->headers != NULL) {
        curl_slist_free_all(connection->headers);
    }
    free(connection);
}
