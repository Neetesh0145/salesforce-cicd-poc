@IsTest
private class CiCdHealthCheckTest {
    @IsTest
    static void pingReturnsMessage() {
        Test.startTest();
        String result = CiCdHealthCheck.ping();
        Test.stopTest();

        Assert.areEqual('CI/CD pipeline is alive', result, 'Health check message changed unexpectedly');
    }
}
