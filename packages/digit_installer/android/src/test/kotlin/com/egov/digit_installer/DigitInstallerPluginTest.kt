package com.egov.digit_installer

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test

/*
 * Full method-channel coverage requires a real Context (Activity/session
 * APIs), which isn't available in a plain JVM unit test — see the
 * integration test plan in the package's implementation notes for the
 * on-device checklist. This smoke-tests the dispatch fallback, which is
 * reachable without any native Android dependencies.
 */
internal class DigitInstallerPluginTest {
    @Test
    fun onMethodCall_unknownMethod_isNotImplemented() {
        val plugin = DigitInstallerPlugin()

        val call = MethodCall("someUnknownMethod", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).notImplemented()
    }
}
